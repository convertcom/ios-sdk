// MockClock.swift
// The `Clock` test double, extracted from `MockPorts.swift` once its stepping API grew (the
// combined file exceeded SwiftLint's 400-line `file_length` limit). It depends only on the
// `LockedBox` primitive that remains in `MockPorts.swift` (same test target) and on the `Clock`
// port — no behavior change from the move. See `MockPorts.swift`'s header for the per-mock
// concurrency-shape rationale (this is the `final class` + `LockedBox` synchronous-port shape).

import Foundation
import ConvertSDK

// MARK: - MockClock

/// Test double for ``Clock`` with a CONTINUATION-GATED virtual-clock stepping API.
///
/// Shape: `final class` + ``LockedBox`` — `now` is a synchronous getter, which an actor cannot
/// satisfy, so this is the one port for which `final class` + a lock is mandatory. Tests inject
/// deterministic time via ``setNow(_:)`` and (in stepping mode) advance the clock one parked
/// ``sleep(milliseconds:)`` at a time via ``tick()``.
///
/// ── Why stepping (the test-infrastructure problem this solves) ─────────────────────────────
/// A refresh loop is written `while !Task.isCancelled { await clock.sleep(ms); await work() }`.
/// If `sleep` returned immediately (the Story 1.3 stand-in behavior), that loop would SPIN HOT —
/// firing `work()` thousands of times in a tight async loop — making "assert exactly one fetch
/// after one interval" impossible to express deterministically and risking a runaway test. In
/// stepping mode each `sleep` PARKS on a continuation until the test calls ``tick()``, which
/// resumes EXACTLY ONE parked sleeper (advancing the loop by exactly one iteration) and moves
/// ``now`` forward by that sleeper's recorded duration so TTL math progresses. No wall-clock
/// wait ever occurs (NFR21) — the wait is a pure continuation handoff, the same mechanism the
/// ``MockConfigProvider`` gate uses.
///
/// ── No lost wakeup (tick/park order independence) ──────────────────────────────────────────
/// A naïve "resume the parked sleeper" would HANG if ``tick()`` ran before the loop reached
/// `sleep` (nothing parked to resume → the next `sleep` parks forever). This clock instead keeps
/// a CREDIT counter: ``tick()`` resumes a parked sleeper if one exists, else banks a credit; the
/// next `sleep` consumes a banked credit and returns immediately instead of parking. So tick and
/// park are order-independent — neither a tick-before-park nor a park-before-tick can deadlock.
///
/// ── `autoAdvance` mode (the Story 1.3 immediate-return behavior) ───────────────────────────
/// `autoAdvance: true` restores the original "record and resume immediately" `sleep` (advancing
/// ``now`` by the recorded ms), for any caller that does NOT want to drive the loop tick-by-tick.
/// The stepping suites pass the default `autoAdvance: false`.
///
/// ── Sendable soundness ─────────────────────────────────────────────────────────────────────
/// All mutable state lives in a single ``LockedBox`` ``State`` cell (parked continuations +
/// banked credits + recorded sleeps), so the class is `Sendable` with NO new suppression beyond
/// the audited ``LockedBox`` primitive. Every continuation is captured UNDER the lock and resumed
/// OUTSIDE it (the lock is released before `resume`), so a continuation is never resumed while the
/// lock is held — and each parked continuation is resumed exactly once.
final class MockClock: Clock {
    /// One parked sleeper: its continuation, a unique id (so cancellation can target exactly this
    /// sleeper), and the duration it was asked to sleep (used to advance ``now`` when resumed by a
    /// ``tick()``). A named struct keeps the `large_tuple` lint rule satisfied.
    private struct Parked {
        let id: Int
        let continuation: CheckedContinuation<Void, Never>
        let milliseconds: Int
    }

    /// All lock-guarded mutable state, held in one ``LockedBox`` cell.
    private struct State {
        /// The current instant returned by ``now``.
        var now: Date
        /// FIFO queue of sleepers parked in stepping mode, awaiting a ``tick()`` (or cancellation).
        var parked: [Parked] = []
        /// Banked `tick()` credits that arrived before any sleeper had parked. The next `sleep`
        /// consumes one (returning immediately, advancing ``now`` by its OWN recorded duration)
        /// instead of parking — closing the lost-wakeup race. Time always advances by the
        /// SLEEPER's duration (decided at park/consume time), never by a `tick` argument, so the
        /// credit needs no stored duration of its own.
        var credits = 0
        /// The `milliseconds` of every ``sleep(milliseconds:)`` call, in call order.
        var recordedSleeps: [Int] = []
        /// Monotonic id source for parked sleepers (so a cancellation handler resumes the right one).
        var nextId = 0
        /// Ids whose cancellation arrived BEFORE the sleeper parked (the `onCancel` handler can run
        /// before the operation body). The parking `sleep` checks this and returns immediately
        /// instead of parking — closing the cancel-before-park race, mirroring the `credits` fix.
        var cancelledBeforePark: Set<Int> = []
    }

    private let state: LockedBox<State>
    /// When `true`, ``sleep`` records and resumes immediately (advancing ``now``); when `false`
    /// (the default), ``sleep`` parks until a ``tick()`` resumes it. Immutable after init.
    private let autoAdvance: Bool

    init(now: Date = Date(timeIntervalSince1970: 0), autoAdvance: Bool = false) {
        self.state = LockedBox(State(now: now))
        self.autoAdvance = autoAdvance
    }

    var now: Date {
        state.withLock { $0.now }
    }

    /// The `milliseconds` of each recorded ``sleep(milliseconds:)`` call, in call order.
    var sleeps: [Int] {
        state.withLock { $0.recordedSleeps }
    }

    /// Sets the instant returned by ``now`` directly (TTL tests that move time without a tick).
    func setNow(_ date: Date) {
        state.withLock { $0.now = date }
    }

    /// Resumes EXACTLY ONE parked ``sleep(milliseconds:)`` (FIFO), advancing ``now`` by that
    /// sleeper's recorded duration so the loop proceeds one iteration. If no sleeper is parked yet
    /// (the ``tick()`` arrived first), banks a credit so the NEXT `sleep` returns immediately
    /// instead of parking — no lost wakeup. The continuation is captured under the lock and
    /// resumed AFTER the lock is released. No-op effect on `autoAdvance` clocks (sleeps never park
    /// there, so a tick just banks an unused credit).
    func tick() {
        let toResume: CheckedContinuation<Void, Never>? = state.withLock { state in
            guard !state.parked.isEmpty else {
                state.credits += 1
                return nil
            }
            let next = state.parked.removeFirst()
            state.now = state.now.addingTimeInterval(Double(next.milliseconds) / 1000)
            return next.continuation
        }
        toResume?.resume()
    }

    /// Records the requested duration, then either resumes immediately (`autoAdvance`, or a banked
    /// ``tick()`` credit is available) or PARKS until a ``tick()`` resumes it — OR until the
    /// awaiting task is CANCELLED. Cancellation-awareness mirrors ``SystemClock/sleep(milliseconds:)``
    /// (whose `Task.sleep` returns on cancel): a cancelled refresh loop must resume from its sleep
    /// so it can observe `Task.isCancelled` and exit, rather than leaking a forever-parked task. The
    /// continuation is stored under the lock and resumed exactly once — by ``tick()``, or by the
    /// cancellation handler, whichever fires first (the id + `cancelledBeforePark` set make the two
    /// order-independent). No wall-clock wait on any path (NFR21).
    func sleep(milliseconds: Int) async {
        let parkId: Int? = state.withLock { state in
            state.recordedSleeps.append(milliseconds)
            if autoAdvance {
                state.now = state.now.addingTimeInterval(Double(milliseconds) / 1000)
                return nil
            }
            if state.credits > 0 {
                state.credits -= 1
                state.now = state.now.addingTimeInterval(Double(milliseconds) / 1000)
                return nil
            }
            let id = state.nextId
            state.nextId += 1
            return id
        }
        guard let parkId else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = state.withLock { state in
                    // The cancellation handler may have already fired for this id (cancel-before-park):
                    // consume that signal and resume immediately instead of parking — no lost wakeup.
                    if state.cancelledBeforePark.remove(parkId) != nil {
                        return true
                    }
                    state.parked.append(Parked(id: parkId, continuation: continuation, milliseconds: milliseconds))
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            let toResume: CheckedContinuation<Void, Never>? = state.withLock { state in
                guard let index = state.parked.firstIndex(where: { $0.id == parkId }) else {
                    // Not parked yet — record the cancellation so the imminent park resumes at once.
                    state.cancelledBeforePark.insert(parkId)
                    return nil
                }
                return state.parked.remove(at: index).continuation
            }
            toResume?.resume()
        }
    }
}
