// Tests/ConvertSDKTests/Lifecycle/ConfigRefreshSchedulerTests.swift
//
// RED-phase contract for `ConfigRefreshScheduler` (Epic 2 / Story 2.4 — foreground config
// refresh + Low-Power-Mode pause). The actor does NOT exist yet — the GREEN step creates it at
// `Sources/ConvertSDK/Lifecycle/ConfigRefreshScheduler.swift`. Every reference here goes through
// the `makeSchedulerSut(...)` factory (in `TestFixtures.swift`), whose return type names
// `ConfigRefreshScheduler`, so this whole suite fails to compile with "cannot find type
// 'ConfigRefreshScheduler' in scope" until GREEN — the expected RED state for this TDD cycle.
//
// ── Contract under test (the GREEN implementer MUST satisfy these) ──────────────────────────
// - `start()` launches three loops: an interval loop (`while !Task.isCancelled { await
//   clock.sleep(refreshIntervalMs); await attemptRefreshIfDue() }`), a foreground observer
//   (`notifications(named:)` → `attemptRefreshIfDue(skipTTL: false)`), and a power-state observer
//   (`.NSProcessInfoPowerStateDidChange` → `handlePowerStateChange()`).            [AC1, AC3, AC5, AC6]
// - `attemptRefreshIfDue(skipTTL:)`: power mode on → skip (log `.debug`); else `!skipTTL` and
//   `clock.now - lastSuccessfulFetchAt < refreshIntervalMs` → skip (log `.debug`); else refresh. [AC4, AC5]
// - `performRefresh()`: `fetchLiveConfig()`; non-nil → `configStore.setConfig(fresh)` +
//   `lastSuccessfulFetchAt = clock.now`; nil → log `.warn`, store untouched, NO event fired.   [AC1, AC7]
// - `handlePowerStateChange()`: LPM now false → log `.info` + `attemptRefreshIfDue(skipTTL: true)`. [AC6]
// - `cancel()`: cancels the three tasks.                                                          [AC10]
//
// ── TTL TIME SOURCE — load-bearing implementer note (AC12) ──────────────────────────────────
// The TTL check MUST read the injected `clock.now` (NOT `Date()`), and `lastSuccessfulFetchAt`
// MUST be set from `clock.now`. AC12 mandates injectable time ("tests inject a `MockClock` …
// never a wall-clock"); these tests move time deterministically via `clock.setNow(_:)`, which only
// drives the TTL gate if the gate reads `clock.now`. (The Story 2.4 task-list code SKETCH shows
// `Date().timeIntervalSince(last)`; that sketch contradicts AC12 and the injected-`Clock` contract
// — the GREEN implementer uses `clock.now`.)
//
// ── Determinism WITHOUT wall-clock sleeps (NFR21) ───────────────────────────────────────────
// Two async seams: (1) the interval loop parks on `clock.sleep`, advanced one iteration per
// `clock.tick()` (the continuation-gated `MockClock` — see `MockPorts.swift`); (2) the foreground
// and power-state observers, registered via `NotificationCenter.addObserver(forName:queue:using:)`,
// run their attempt in a DETACHED `Task` the block spawns. Seam (2) is the one that flaked: a
// bounded `drainUntil` poll (N `MainActor` hops) RACED that detached `Task` — under cooperative-pool
// contention (the full ~27-suite parallel run) the `Task`'s `fetchLiveConfig()` had not landed when
// the count was read, so the boundary case saw 1 fetch instead of 2 (~20% of runs under load).
//
// The fix replaces "poll and hope it settled" with a REAL happens-before on the awaited event:
//   * `await sut.fetch.waitForFetchCount(n)` — parks a continuation the fetch double resumes the
//     instant its Nth `fetchLiveConfig()` runs. Used for every wait whose count WILL reach the
//     target (incl. failed fetches, which still increment).
//   * `await sut.logger.waitForEntry(...)` — parks a continuation the matching `log(...)` resumes.
//     Used where the awaited observable is a LOG, not a fetch: the within-TTL `.debug` skip line and
//     the LPM-skip `.debug` line (the gated attempt RAN but performs no fetch, so the count never
//     moves), and the failed-refresh `.warn` line.
// Both are pure continuation handoffs (NFR21 — no wall-clock wait), mirroring `MockConfigProvider`'s
// gate and `ConfigStore.waitForReady()`. `.configUpdated` deliveries (a `MainActor` task) are still
// flushed with `drainMainActor()` before the bus count is read. The ONE remaining bounded
// `drainUntil` is in the cancel test, a NEGATIVE assertion (no event to await — see its doc). No
// test measures elapsed time.
import Testing
import Foundation
@testable import ConvertSDK

@Suite("ConfigRefreshScheduler")
struct ConfigRefreshSchedulerTests {
    // MARK: Shared TTL constants (one source so the parameterized cases read by intent)

    /// The interval used by the TTL suite — small, explicit, and equal to the TTL floor (AC4).
    private static let ttlIntervalMs = 300_000
    /// An elapsed span STRICTLY INSIDE the TTL window → a second attempt is skipped.
    private static let withinTtlMs = 60_000
    /// An elapsed span AT the TTL boundary (`== interval`, so NOT `< interval`) → a second attempt
    /// proceeds. Using the boundary value also pins the comparison as strict `<` (not `<=`).
    private static let beyondTtlMs = 300_000

    /// Advances the SUT's clock so that `clock.now - lastSuccessfulFetchAt == elapsedMs`, given the
    /// first refresh stamped `lastSuccessfulFetchAt` at the clock's start instant (`epoch`). Single
    /// owner of the `setNow` arithmetic so the two TTL cases do not re-inline it.
    private func advanceClock(_ clock: MockClock, byMs elapsedMs: Int) {
        clock.setNow(Date(timeIntervalSince1970: Double(elapsedMs) / 1000))
    }

    // MARK: Scenario 1 — interval tick fetches and writes the fresh config

    /// AC1: one interval tick performs a refresh — exactly one `fetchLiveConfig()` AND the store is
    /// updated, observable as a single `.configUpdated` (the store was pre-readied, so the
    /// scheduler's `setConfig(fresh)` is a post-ready refresh, not the one-shot `.ready`).
    @Test("an interval tick fetches once and writes the fresh config to the store")
    func intervalRefreshFetchesAndSetsConfig() async throws {
        let sut = try await makeSchedulerSut()
        let updates = await countEvents(.configUpdated, on: sut.bus)
        await sut.scheduler.start()

        // Release exactly one interval sleep so the loop runs ONE iteration, then AWAIT the fetch
        // actually happening (a real happens-before via the fetch double's continuation, not a
        // bounded poll). `setConfig` fires `.configUpdated` on the `MainActor` AFTER the fetch
        // returns, so a `drainMainActor()` barrier still flushes that delivery before `firings` is
        // read.
        sut.clock.tick()
        await sut.fetch.waitForFetchCount(1)
        await drainMainActor()

        #expect(await sut.fetch.fetchLiveConfigCallCount == 1)
        #expect(updates.firings == 1)
        #expect(await sut.store.getSnapshot()?.accountId == "acc-live")

        await sut.scheduler.cancel()
        await sut.bus.off(updates.token)
    }

    // MARK: Scenario 2 — lazy TTL boundary (within vs beyond)

    /// Shared first-attempt setup for the two TTL cases: build the TTL-interval SUT, start it, fire
    /// the FIRST foreground attempt (no prior fetch → it always refreshes, stamping
    /// `lastSuccessfulFetchAt = epoch`), and AWAIT that first fetch landing via a real happens-before.
    /// Then advance the clock by `elapsedMs` and fire the SECOND foreground attempt — WITHOUT waiting
    /// on its outcome, because the two cases observe DIFFERENT outcomes (beyond → a second fetch
    /// lands; within → the attempt is gated and logs a skip, the count never moving). Factored to one
    /// owner so the within/beyond bodies do not re-inline the identical first-attempt block (SonarQube
    /// new-duplicated-lines gate; CPD is token-based, so sharing the block — not renaming locals — is
    /// what keeps the diff under the threshold). Returns the SUT so each case drives its own wait +
    /// assertion + teardown.
    private func startedSutAfterSecondForegroundAttempt(elapsedByMs elapsedMs: Int) async throws -> SchedulerSUT {
        let sut = try await makeSchedulerSut(refreshIntervalMs: Self.ttlIntervalMs)
        await sut.scheduler.start()

        // First attempt: no prior fetch → always refreshes, stamping lastSuccessfulFetchAt = epoch.
        // Await the fetch itself (continuation handoff), not a bounded poll, so the stamp is in place
        // before the clock moves.
        triggerForeground(center: sut.center)
        await sut.fetch.waitForFetchCount(1)

        // Move time, then a SECOND foreground attempt (TTL applies on foreground, AC4/Task 2.2).
        advanceClock(sut.clock, byMs: elapsedMs)
        triggerForeground(center: sut.center)
        return sut
    }

    /// AC4: a second foreground attempt at/AFTER the TTL boundary (`elapsed == interval`, so NOT
    /// `< interval`) PROCEEDS — exactly two fetches. Awaiting `waitForFetchCount(2)` is a genuine
    /// happens-before on the second fetch (the fix for the prior ~20%-under-load flake: a bounded
    /// `drainUntil` RACED the detached `Task` the foreground `NotificationCenter` block spawns, and
    /// under cooperative-pool contention the second fetch had not landed when the count was read).
    @Test("the lazy TTL allows a second attempt at the boundary")
    func ttlBoundaryAllowsSecondAttempt() async throws {
        let sut = try await startedSutAfterSecondForegroundAttempt(elapsedByMs: Self.beyondTtlMs)

        // Await the legitimate second fetch landing — a real event, not a settled-by-timeout poll.
        await sut.fetch.waitForFetchCount(2)
        #expect(await sut.fetch.fetchLiveConfigCallCount == 2)

        await sut.scheduler.cancel()
    }

    /// AC4: a second foreground attempt WITHIN the TTL window is SKIPPED — the count stays 1. The
    /// skipped attempt cannot be awaited via `waitForFetchCount(2)` (that threshold never arrives and
    /// would park forever); instead this awaits the scheduler's `.debug` TTL-skip line — the
    /// deterministic proof the second attempt RAN and was GATED — via `MockLogger.waitForEntry`, THEN
    /// asserts the count is still 1. (`messageContains: "last fetch"` pins it to the TTL skip, not the
    /// LPM skip, which shares the same `.debug`/`checkRefresh` coordinates.)
    @Test("the lazy TTL skips a second attempt within the window")
    func ttlWindowSkipsSecondAttempt() async throws {
        let sut = try await startedSutAfterSecondForegroundAttempt(elapsedByMs: Self.withinTtlMs)

        // Await the skip log (the gated second attempt's observable), not a count that won't move.
        await sut.logger.waitForEntry(
            level: .debug,
            type: "ConfigRefreshScheduler",
            method: "checkRefresh",
            messageContains: "last fetch"
        )
        #expect(await sut.fetch.fetchLiveConfigCallCount == 1)

        await sut.scheduler.cancel()
    }

    // MARK: Scenario 3 — foreground notification triggers a refresh

    /// AC3: a foreground transition triggers an immediate refresh attempt independent of the timer.
    /// Gated to platforms with a foreground notification (the CI test host is the iOS Simulator,
    /// where `UIApplication.willEnterForegroundNotification` exists); absent on a pure-macOS
    /// `swift test` where app-foreground semantics are out of scope for this contract.
    #if canImport(UIKit)
    @Test("posting the foreground notification triggers a fetch")
    func foregroundNotificationTriggersRefresh() async throws {
        let sut = try await makeSchedulerSut()
        await sut.scheduler.start()

        triggerForeground(center: sut.center)
        await sut.fetch.waitForFetchCount(1)

        #expect(await sut.fetch.fetchLiveConfigCallCount == 1)

        await sut.scheduler.cancel()
    }
    #endif

    // MARK: Scenario 4 — Low Power Mode pauses interval polling

    /// AC5: under LPM the interval-fired attempt is suppressed — an interval tick performs NO
    /// fetch. The loop itself keeps running (so it can detect LPM exit); only the fetch is gated.
    @Test("Low Power Mode suppresses the interval-fired refresh")
    func lpmPausesIntervalRefresh() async throws {
        let sut = try await makeSchedulerSut(powerMode: true)
        await sut.scheduler.start()

        // Drive one interval iteration; the LPM guard must skip the fetch. Await the LPM-skip
        // `.debug` line — the deterministic proof the interval-fired attempt RAN and was GATED (a
        // real happens-before via `MockLogger.waitForEntry`) — rather than polling a clock-sleep
        // count, which only INDIRECTLY implies the gated attempt completed. The skip never fetches,
        // so `waitForFetchCount` is not applicable (the count stays 0); the log is the right signal.
        sut.clock.tick()
        await sut.logger.waitForEntry(
            level: .debug,
            type: "ConfigRefreshScheduler",
            method: "checkRefresh",
            messageContains: "Low Power Mode"
        )

        #expect(await sut.fetch.fetchLiveConfigCallCount == 0)

        await sut.scheduler.cancel()
    }

    // MARK: Scenario 5 — exiting Low Power Mode triggers an immediate refresh

    /// AC6: when LPM exits, the power-state notification drives an immediate (TTL-skipping) refresh.
    /// The SUT starts in LPM; the test flips the power-mode cell to `false` (so the handler re-reads
    /// `false`) BEFORE posting `.NSProcessInfoPowerStateDidChange` — exactly the LPM-exit sequence.
    /// That notification is Foundation-level (macOS 12+ / iOS 9+), so this runs on every host the
    /// package targets — no platform guard.
    @Test("exiting Low Power Mode triggers an immediate refresh")
    func lpmExitTriggersImmediateRefresh() async throws {
        let sut = try await makeSchedulerSut(powerMode: true)
        await sut.scheduler.start()

        sut.setPowerMode(false)
        triggerPowerStateChange(center: sut.center)
        await sut.fetch.waitForFetchCount(1)

        #expect(await sut.fetch.fetchLiveConfigCallCount == 1)

        await sut.scheduler.cancel()
    }

    // MARK: Scenario 6 — a failed refresh logs WARN and leaves the store unchanged

    /// AC7: a refresh whose `fetchLiveConfig()` yields `nil` (network/decode failure) must NOT touch
    /// the store (the pre-ready snapshot is still served) and must log exactly one `.warn`. Driven
    /// via the foreground path with `live: nil` injected.
    @Test("a failed refresh logs WARN and does not change the store snapshot")
    func failedRefreshLogsWarnAndDoesNotChangeStore() async throws {
        let sut = try await makeSchedulerSut(live: nil)
        await sut.scheduler.start()

        triggerForeground(center: sut.center)
        // Await the WARN itself landing — the actual asserted observable on this (failure) path —
        // via a genuine happens-before (`MockLogger.waitForEntry` parks a continuation the WARN's
        // `log(...)` resumes), replacing the bounded `drainUntil` poll. The WARN is emitted in
        // `performRefresh` AFTER the (failed) `fetchLiveConfig()` increments the count, so first
        // awaiting the fetch and then the WARN orders the two observables the assertions read.
        await sut.fetch.waitForFetchCount(1)
        await sut.logger.waitForEntry(level: .warn, type: "ConfigRefreshScheduler")

        #expect(await sut.fetch.fetchLiveConfigCallCount >= 1)
        // Store untouched → still the pre-ready snapshot, never overwritten to the (nil) live result.
        #expect(await sut.store.getSnapshot()?.accountId == "acc-cached")
        // Exactly one WARN from the scheduler's failed-refresh path.
        #expect(sut.logger.entries(type: "ConfigRefreshScheduler").filter { $0.level == .warn }.count == 1)

        await sut.scheduler.cancel()
    }

    // MARK: Scenario 7 — a failed refresh fires no new event

    /// AC7: a failed refresh fires NO `.configUpdated` (and invents no new event) — the store is
    /// never written, so the bus stays silent for the refresh. Counts `.configUpdated` on the
    /// store's bus across the failed attempt and asserts zero.
    @Test("a failed refresh fires no .configUpdated event")
    func failedRefreshDoesNotFireNewEvent() async throws {
        let sut = try await makeSchedulerSut(live: nil)
        let updates = await countEvents(.configUpdated, on: sut.bus)
        await sut.scheduler.start()

        triggerForeground(center: sut.center)
        // A FAILED fetch still increments the call count, so awaiting it is a real happens-before on
        // the refresh attempt completing; then `drainMainActor()` flushes any (here: none) pending
        // `.configUpdated` delivery before `firings` is read.
        await sut.fetch.waitForFetchCount(1)
        await drainMainActor()

        #expect(updates.firings == 0)

        await sut.scheduler.cancel()
        await sut.bus.off(updates.token)
    }

    // MARK: Scenario 8 — cancel stops the loops

    /// AC10: after `cancel()`, the interval loop performs no further fetch. `cancel()` cancels the
    /// tasks; the continuation-gated `MockClock` is cancellation-aware (it resumes a parked sleep on
    /// cancel, mirroring `SystemClock`'s `Task.sleep`), so the loop resumes from its sleep and — IF
    /// it guards `Task.isCancelled` AFTER the sleep (required for clean teardown under AC10; the
    /// Story 2.4 loop sketch omits the post-sleep guard, the implementer MUST add it) — exits
    /// WITHOUT a trailing `attemptRefreshIfDue`. The post-cancel `tick()` would resume any sleeper
    /// that somehow re-parked; the bounded drain then gives a (wrongly) surviving loop turns to run,
    /// so a teardown regression surfaces as a count increase rather than being masked by timing.
    ///
    /// Why this test KEEPS the bounded `drainUntil` while every fetch-DRIVEN wait in this suite became
    /// a `waitForFetchCount`/`waitForEntry` continuation await: this is a NEGATIVE assertion — the
    /// correct behavior emits NO event (no fetch, no log), so there is no positive signal to park a
    /// continuation on, and `waitForFetchCount` would hang forever waiting for a count that must never
    /// move. A bounded drain is the right instrument for proving a non-event: it can only fail by a
    /// FALSE PASS (a real teardown bug whose spurious fetch did not land in the bound) — never the
    /// FALSE FAIL that the ~20%-under-load flake was (correct production, fetch not yet landed). The
    /// only way to make this a happens-before would be to make `cancel()`'s loop-exit observable from
    /// production, which is out of scope (no production-dispatch change). The bound stays at the
    /// shared default — it is NOT bumped as part of the flake fix.
    @Test("cancel stops the interval loop so no further fetch occurs")
    func cancelStopsAllTasks() async throws {
        let sut = try await makeSchedulerSut()
        await sut.scheduler.start()
        await sut.scheduler.cancel()

        let before = await sut.fetch.fetchLiveConfigCallCount
        sut.clock.tick()
        await drainUntil { await sut.fetch.fetchLiveConfigCallCount > before }

        #expect(await sut.fetch.fetchLiveConfigCallCount == before)
    }
}
