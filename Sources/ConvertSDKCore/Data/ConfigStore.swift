// ConfigStore.swift
// Minimal config-presence/ready-gate actor (Epic 2 / Story 2; expanded in Story 2.3).
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Owns the "config is present" state, the current config snapshot, and the one-shot ready gate.
///
/// Carries the typed config (Story 2.3): ``setConfig(_:)`` takes a `ProjectConfig?` payload,
/// stores it as the current ``snapshot``, and — on the FIRST non-terminal call — flips the
/// ready flag, fires `.ready` once, and resumes any ``waitForReady()`` waiters. A `nil`
/// argument is a valid DEGRADED first load (F-019): it still signals ready so the SDK never
/// hangs when both cache and network fail, just with a `nil` snapshot. ``getSnapshot()`` reads
/// back the value last passed to ``setConfig(_:)``.
///
/// All mutable state (`snapshot`, `isReady`, `terminalError`, `continuations`) is
/// actor-isolated, so the ready gate is race-free with no locks (AR12).
///
/// The gate is a one-shot, latched state machine with three states: *pending* → *ready*
/// (success/degraded via ``setConfig(_:)``) or *errored* (unrecoverable via ``signalError(_:)``).
/// BOTH terminal states latch: once reached, ``waitForReady()`` resolves the SAME way for every
/// later caller, and the first terminal transition wins. A subsequent ``setConfig(_:)`` still
/// UPDATES the snapshot (so the latest config is always readable) but does NOT re-fire `.ready`
/// or re-signal; a subsequent ``signalError(_:)`` is a no-op. Latching the error state — not
/// just the success state — is what makes a ``waitForReady()`` that registers AFTER
/// ``signalError(_:)`` still throw rather than suspend forever (otherwise its continuation would
/// never be resumed → a permanent hang).
public actor ConfigStore {
    /// The owned bus on which `.ready` is fired exactly once.
    private let eventBus: EventBus
    /// Whether the first config has landed (success terminal state). Once `true`, stays `true`.
    private var isReady = false
    /// The unrecoverable error the gate failed with (error terminal state), or `nil` while the
    /// gate has not failed. Once set, stays set — so a ``waitForReady()`` arriving after
    /// ``signalError(_:)`` throws immediately instead of suspending on a continuation that
    /// nothing would ever resume.
    private var terminalError: ConvertError?
    /// Waiters suspended in ``waitForReady()`` before config arrived, keyed by a per-call
    /// `UUID` so a cancelled waiter can be de-registered individually (F-170) without disturbing
    /// the others. Resumed en masse by ``setConfig(_:)``/``signalError(_:)``, or one-at-a-time by
    /// ``cancelWaiter(_:)`` on task cancellation.
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// The current config snapshot: the value last passed to ``setConfig(_:)``, or `nil` (no
    /// config yet, or a DEGRADED load resolved with no typed config). Actor-isolated, and
    /// `ProjectConfig` is `Sendable`, so storing it here is data-race-safe. Read via
    /// ``getSnapshot()``; updated by EVERY ``setConfig(_:)`` (even a post-ready one), so the
    /// latest config is always readable independent of the one-shot ready latch.
    private var snapshot: ProjectConfig?

    /// Creates a store that fires `.ready` on the supplied bus.
    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    /// Stores `config` as the current ``snapshot`` and, on the FIRST non-terminal call, marks
    /// config present: fires `SystemEvent.ready` exactly once via the owned ``EventBus`` and
    /// resumes every ``waitForReady()`` waiter. A `nil` argument is a valid DEGRADED first load
    /// (F-019): it STILL signals ready (the guard passes), preventing a forever-hang when both
    /// cache and network fail, just with a `nil` snapshot.
    ///
    /// The snapshot is stored BEFORE the latch guard, so a SECOND (post-ready) call still
    /// UPDATES the snapshot to the latest config — but then returns without re-firing `.ready`
    /// or re-signalling waiters (the gate latches; the first terminal transition already won).
    /// `.ready` is fired BEFORE resuming continuations, so `.ready` subscribers observe the
    /// event before any ``waitForReady()`` caller unblocks (Story 2.2 ordering). `async`
    /// because firing on the bus actor is an `await`ed cross-actor call.
    public func setConfig(_ config: ProjectConfig?) async {
        snapshot = config
        guard !isReady, terminalError == nil else { return }
        isReady = true
        await eventBus.fire(.ready, payload: .ready(ReadyPayload()))
        for continuation in continuations.values {
            continuation.resume()
        }
        continuations.removeAll()
    }

    /// Returns the current config snapshot: the value last passed to ``setConfig(_:)``, or `nil`
    /// when no config has been set or the load resolved DEGRADED. Synchronous (non-`async`) — a
    /// plain actor-isolated read of ``snapshot``; an external caller still `await`s the actor
    /// hop, but there is no internal suspension point.
    public func getSnapshot() -> ProjectConfig? {
        snapshot
    }

    /// Suspends until the gate reaches a terminal state: returns on ``setConfig(_:)``
    /// (success/degraded), throws the ``ConvertError`` on ``signalError(_:)`` (unrecoverable),
    /// or throws `CancellationError` if the awaiting task is cancelled before either terminal
    /// transition. Returns or throws IMMEDIATELY if the gate is already terminal — or the task
    /// already cancelled — when called: the success latch (`isReady`), the error latch
    /// (`terminalError`), and `Task.isCancelled` are all checked before suspending, so a caller
    /// that arrives after a terminal/cancelled transition is resolved synchronously rather than
    /// registering a continuation that nothing would resume.
    ///
    /// Cancellation-aware (F-170, FR44). The suspend is wrapped in
    /// ``withTaskCancellationHandler(operation:onCancel:)`` and the continuation is keyed by a
    /// fresh `UUID` in ``continuations``. If the awaiting task is cancelled while suspended,
    /// ``cancelWaiter(_:)`` de-registers that ONE waiter and resumes it throwing
    /// `CancellationError` — so a caller that wraps its own timeout around `ready()` unblocks
    /// PROMPTLY instead of stalling until the URLSession request timeout (~30 s). The terminal
    /// and `Task.isCancelled` re-checks INSIDE the continuation body close the
    /// cancel-before-register and resolve-before-register races (the body runs actor-isolated).
    public func waitForReady() async throws {
        if isReady { return }
        if let terminalError { throw terminalError }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Re-check the latches and cancellation here, inside the actor-isolated body:
                // between the early-out guards above and this point the gate may have gone
                // terminal, or the task may have been cancelled before the handler installed.
                // Resolving here instead of registering closes both races.
                if isReady {
                    continuation.resume()
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[id] = continuation
                }
            }
        } onCancel: {
            // Runs OUTSIDE actor isolation, synchronously on the cancelling task. Hop back onto
            // the actor to de-register and resume the specific waiter; a no-op if a terminal
            // transition already resumed it (``cancelWaiter(_:)`` guards with `removeValue`).
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Resumes the single ``waitForReady()`` waiter registered under `id` by throwing
    /// `CancellationError`, after de-registering it. A no-op if that waiter was already resumed
    /// by ``setConfig(_:)``/``signalError(_:)`` (`removeValue` returns `nil`), so a continuation
    /// is never resumed twice. Actor-isolated; invoked from the `onCancel` handler's hop-on `Task`.
    private func cancelWaiter(_ id: UUID) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    /// Fails the ready gate with an unrecoverable configuration error: latches the error and
    /// resumes every pending ``waitForReady()`` waiter by *throwing* `error`, so `ready()`
    /// surfaces the ``ConvertError``. The error state LATCHES (stored in `terminalError`), so a
    /// ``waitForReady()`` that registers after this call also throws — without the latch its
    /// continuation would never be resumed and `ready()` would hang forever. A no-op once the
    /// gate is already terminal (ready or errored): the first terminal transition wins. `.ready`
    /// is NOT fired on this path.
    public func signalError(_ error: ConvertError) {
        guard !isReady, terminalError == nil else { return }
        terminalError = error
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
        continuations.removeAll()
    }

    /// Validates `config`'s SDK key and returns the ``ConvertError`` if it is invalid, or `nil`
    /// if it is valid. A pure validation bridge — it does NOT touch the gate — so the SDK's
    /// config-load task can validate, then (on `nil`) run the loader, then ``setConfig(_:)``,
    /// keeping the loader call between validation and readiness.
    ///
    /// Lives on the store because the ``ConfigValidation`` it calls is `internal` to this
    /// module: the cross-module SDK target cannot invoke it, but the store — same module —
    /// can.
    public func validationError(for config: ConvertConfiguration) -> ConvertError? {
        do {
            try ConfigValidation.validate(config)
            return nil
        } catch {
            return error
        }
    }

    /// Validates pre-fetched config `data`, then resolves the gate: on non-empty data, marks
    /// config present via ``setConfig(_:)``; on empty/invalid data, fails the gate via
    /// ``signalError(_:)`` so `ready()` throws. The direct-data path has no loader step, so
    /// validation and readiness are a single store operation here (Story 2.3 adds the real
    /// structural decode in the validator).
    public func validateAndSetConfig(data: Data) async {
        do {
            try ConfigValidation.validate(data)
        } catch {
            // `signalError` is intentionally synchronous (non-`async`): it must run to
            // completion on this actor without yielding between catching the validation
            // error and latching/resuming on it, so no interleaved `setConfig`/`signalError`
            // can race the terminal transition.
            signalError(error)
            return
        }
        // This path has validated raw bytes but has no typed `ProjectConfig` to hand over (it
        // does NOT decode the data into `ProjectConfig` — that is out of scope here), so it
        // resolves DEGRADED ready with a `nil` snapshot, preserving the original intent that
        // valid data still resolves `ready()`.
        await setConfig(nil)
    }
}
