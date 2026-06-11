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
// `clock.tick()` (the continuation-gated `MockClock` — see `MockPorts.swift`); (2) the
// notification observers deliver on their OWN `Task` (the `notifications(named:)` AsyncSequence).
// For (2) there is no continuation to release, so the test yields the cooperative thread a BOUNDED
// number of times (`drainUntil`) until the observed effect (a fetch-count increment) lands — a
// delivery drain, never a timing assert. `.configUpdated` deliveries (a `MainActor` task) are
// flushed with `drainMainActor()` before the count is read. No test measures elapsed time.
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

        // Release exactly one interval sleep so the loop runs ONE iteration, then let the resulting
        // fetch + setConfig land (bounded yield drain — not a timing wait).
        sut.clock.tick()
        await drainUntil { await sut.fetch.fetchLiveConfigCallCount == 1 }
        await drainMainActor()

        #expect(await sut.fetch.fetchLiveConfigCallCount == 1)
        #expect(updates.firings == 1)
        #expect(await sut.store.getSnapshot()?.accountId == "acc-live")

        await sut.scheduler.cancel()
        await sut.bus.off(updates.token)
    }

    // MARK: Scenario 2 — lazy TTL boundary (parameterized: within vs beyond)

    /// AC4: a second attempt WITHIN the TTL window is skipped (1 fetch); a second attempt at/AFTER
    /// the TTL boundary proceeds (2 fetches). Parameterized over `(elapsedMs, expectedFetches)` so
    /// the within/beyond cases share one body (SonarQube new-duplicated-lines gate) — the only
    /// difference is how far the clock advances before the second foreground attempt.
    @Test(
        "the lazy TTL skips a second attempt within the window and allows it at the boundary",
        arguments: [
            (elapsedMs: ConfigRefreshSchedulerTests.withinTtlMs, expectedFetches: 1),
            (elapsedMs: ConfigRefreshSchedulerTests.beyondTtlMs, expectedFetches: 2)
        ]
    )
    func ttlBoundaryGovernsSecondAttempt(elapsedMs: Int, expectedFetches: Int) async throws {
        let sut = try await makeSchedulerSut(refreshIntervalMs: Self.ttlIntervalMs)
        await sut.scheduler.start()

        // First attempt: no prior fetch → always refreshes, stamping lastSuccessfulFetchAt = epoch.
        triggerForeground(center: sut.center)
        await drainUntil { await sut.fetch.fetchLiveConfigCallCount == 1 }

        // Move time, then a SECOND foreground attempt (TTL applies on foreground, AC4/Task 2.2).
        advanceClock(sut.clock, byMs: elapsedMs)
        triggerForeground(center: sut.center)
        // Drain toward the BEYOND outcome (2 fetches): for the beyond case this returns once the
        // legitimate second fetch lands; for the within case the condition never holds, so the bound
        // is fully spent — giving a (wrongly) un-gated second fetch every chance to land before the
        // assertion. Either way the count has SETTLED when asserted, so a TTL regression can't slip
        // through a too-early check. (The first fetch already made `== 1` true, so a `== 1` drain
        // here would return instantly and mask a buggy second fetch.)
        await drainUntil { await sut.fetch.fetchLiveConfigCallCount >= 2 }

        #expect(await sut.fetch.fetchLiveConfigCallCount == expectedFetches)

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
        await drainUntil { await sut.fetch.fetchLiveConfigCallCount == 1 }

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

        // Drive one interval iteration; the LPM guard must skip the fetch.
        sut.clock.tick()
        await drainUntil { sut.clock.sleeps.count >= 2 }

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
        await drainUntil { await sut.fetch.fetchLiveConfigCallCount == 1 }

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
        await drainUntil { await sut.fetch.fetchLiveConfigCallCount >= 1 }
        await drainMainActor()

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
        await drainUntil { await sut.fetch.fetchLiveConfigCallCount >= 1 }
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
