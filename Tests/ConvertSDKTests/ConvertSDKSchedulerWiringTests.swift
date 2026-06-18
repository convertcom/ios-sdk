// Tests/ConvertSDKTests/ConvertSDKSchedulerWiringTests.swift
//
// RED-phase contract for WIRING the `ConfigRefreshScheduler` into `ConvertSDK.init`
// (Epic 2 / Story 2.4 — PLAT-2 wiring phase). The scheduler ACTOR already exists and is
// unit-tested in isolation (`ConfigRefreshSchedulerTests` drives it through the
// `makeSchedulerSut(...)` factory). What does NOT exist yet is the production wiring that
// CONSTRUCTS and STARTS a scheduler from inside the SDK's detached config-load `Task` — and
// the `clock:` initializer parameter that wiring needs so the suite can advance a virtual clock
// deterministically (NFR21) instead of waiting on the wall clock.
//
// ── What makes this RED, and why it is the RIGHT reason ─────────────────────────────────────
// The SUT helper below calls the internal initializer with a `clock:` argument. `ConvertSDK.init`
// has NO `clock:` parameter today (verified: `Sources/ConvertSDK/ConvertSDK.swift` declares
// `init(configuration:configProvider:eventBus:directData:)` — no clock). So this file fails to
// compile with an "extra argument 'clock' in call" / "incorrect argument label" diagnostic on the
// `clock:` label — exactly the symbol the GREEN (PLAT-2) phase adds. Nothing else here is novel:
// `MockConfigFetchService`, `MockClock`, `makeRefreshConfig`, `countEvents`, and `drainMainActor`
// all already exist (in `Support/TestFixtures.swift` / `Support/MockClock.swift`) and compile
// today. The compile-fail is isolated to the missing `clock:` wiring seam.
//
// ── Assumed GREEN seam (so the implementer matches these call sites) ─────────────────────────
//   internal init(
//       configuration: ConvertConfiguration,
//       configProvider: (any ConfigProviding)? = nil,
//       eventBus: EventBus = EventBus(),
//       directData: Data? = nil,
//       clock: any Clock = SystemClock()        // ← the new parameter (default keeps the public
//                                               //    convenience inits' signatures unchanged)
//   )
// Inside the existing load `Task`, AFTER the cache-then-live `setConfig` sequence that latches
// `ready()`, the wiring constructs a `ConfigRefreshScheduler` over the SAME resolved
// `activeProvider` (reused, not a second instance), the `configStore`, a logger, the injected
// `clock`, and `refreshIntervalMs: configuration.dataRefreshIntervalMs`, then `await scheduler.start()`.
// The scheduler is owned via an IMMUTABLE `let` mechanism (a small `Sendable` box actor) so
// `ConvertSDK` stays an all-`let` `Sendable final class` with NO `@unchecked`/`nonisolated(unsafe)`.
//
// ── Why `MockConfigFetchService` (not `MockConfigProvider`) is the injected seam here ────────
// `MockConfigFetchService` (Support/TestFixtures.swift) is the COUNTING `ConfigProviding` double:
// it records `fetchLiveConfigCallCount` and exposes `waitForFetchCount(_:)` — a genuine
// happens-before on "the Nth `fetchLiveConfig()` has run". It conforms to `ConfigProviding` in
// full: `loadCachedConfig()` returns its `cached` field (default `nil` → a cache MISS), and
// `fetchLiveConfig()` returns its `live` field and increments the count. With a cache miss + a
// non-nil `live`, the SDK init does: cache miss → live fetch (count #1) → `setConfig(live)` →
// `ready()` resolves non-degraded. The scheduler's first interval tick then drives fetch #2 —
// so `waitForFetchCount(2)` after one `clock.tick()` PROVES the scheduler is wired and running
// post-ready. No extension of `MockConfigFetchService` was needed; it already satisfies the port.
//
// ── Determinism (NFR21 — 0-flake under parallel load) ───────────────────────────────────────
// • Fetch-count waits use `MockConfigFetchService.waitForFetchCount` (a real happens-before via a
//   parked continuation), NEVER a poll.
// • `.configUpdated` deliveries (an `EventBus.fire` `MainActor` task) are flushed with
//   `drainMainActor()` (a serial-executor barrier), NEVER `Task.yield()`.
// • The `MockClock` is the continuation-gated stepping clock (`autoAdvance: false`): an interval
//   `sleep` PARKS until `clock.tick()`. It is credit-banking, so a `tick()` issued before the
//   scheduler has parked on its first `sleep` is NOT lost (it banks a credit the next `sleep`
//   consumes) — making the tick/park order immaterial. The `waitForFetchCount(2)` await is the
//   authoritative happens-before regardless of interleaving.
// • No foreground / power-state notifications are posted here, so the scheduler's `.default`
//   `NotificationCenter` observers (the SDK wiring does not thread a custom center into the
//   scheduler for THIS interval-only path) never fire and cannot leak across parallel tests — the
//   interval path is driven purely by `clock.tick()`.
// • No wall-clock waits (NFR21).
//
// NOTE on deinit/cancel coverage: testing `deinit`-driven `cancel()` deterministically is
// ARC/actor-teardown timing-sensitive and would introduce a flake; it is deliberately NOT tested
// here. The scheduler's own teardown contract is covered by
// `ConfigRefreshSchedulerTests.cancelStopsAllTasks` (AC10).
import Testing
import Foundation
@testable import ConvertSDK

@Suite("ConvertSDK scheduler wiring")
struct ConvertSDKSchedulerWiringTests {
    // MARK: - SUT

    /// The wired SDK-under-test plus the collaborators a wiring test drives and observes. A named
    /// struct (not a large tuple) keeps the `large_tuple` lint rule satisfied and lets a test read
    /// collaborators by name. `Sendable` — `ConvertSDK` is a `Sendable final class`, `MockClock`
    /// and `MockConfigFetchService` are `Sendable` doubles, and `EventBus` is `Sendable` — so a
    /// `@Sendable` drain predicate may capture it without a data-race warning.
    private struct WiringSUT: Sendable {
        /// The system under test, constructed with the injected counting provider + stepping clock.
        let sdk: ConvertSDK
        /// The counting `ConfigProviding` double; `waitForFetchCount`/`fetchLiveConfigCallCount`
        /// prove how many `fetchLiveConfig()` calls (init's own + the scheduler's) have run.
        let fetch: MockConfigFetchService
        /// The continuation-gated stepping clock; `tick()` releases ONE interval sleep so the
        /// scheduler's interval loop advances exactly one iteration.
        let clock: MockClock
        /// The bus the SDK fires `.ready` / `.configUpdated` on (and `sdk.on(_:)` forwards to);
        /// subscribe here (directly or via `sdk.on`) to observe the scheduler's post-ready
        /// `setConfig` firing `.configUpdated`.
        let bus: EventBus
    }

    /// Builds a `ConvertSDK` wired to a COUNTING `MockConfigFetchService` (cache miss + a non-nil
    /// `live`, so init resolves non-degraded after fetch #1) and the continuation-gated stepping
    /// `MockClock` (so the scheduler's interval sleep is released only by `clock.tick()`). Single
    /// construction site so neither wiring test re-inlines the configuration build + internal-init
    /// call (SonarQube new-duplicated-lines gate; CPD is token-based, so SHARING this block — not
    /// renaming locals — is what keeps the diff under the threshold).
    ///
    /// `@MainActor` to mirror the existing `ConvertSDKTests.makeSut` (the SDK's internal init is
    /// non-async — the handle is built synchronously and config-load runs in a detached `Task` —
    /// so no `await` is needed here). `throws` because building the `live` `ProjectConfig` decodes
    /// JSON via `makeRefreshConfig` (the shared builder in `TestFixtures.swift`).
    ///
    /// - Parameters:
    ///   - refreshIntervalMs: the interval the wired scheduler sleeps between loop ticks; defaults
    ///     to the production default so the test reads the real wiring value unless it overrides.
    ///   - accountId: the `accountId` carried by the `live` config the fetch double returns —
    ///     assertable so a test can distinguish WHICH config the snapshot holds after a refresh.
    @MainActor
    private func makeWiringSut(
        refreshIntervalMs: Int = Defaults.dataRefreshIntervalMs,
        accountId: String = "acc-live"
    ) throws -> WiringSUT {
        // Cache MISS (default `cached: nil`) + a non-nil `live`: the SDK init's load `Task` does
        // loadCachedConfig() → nil, fetchLiveConfig() → live (count #1), setConfig(live) → ready
        // non-degraded. The scheduler's first interval tick then drives fetch #2.
        let fetch = MockConfigFetchService(live: try makeRefreshConfig(accountId: accountId))
        // Stepping clock: `autoAdvance: false` (the default) so the scheduler's interval `sleep`
        // PARKS until `tick()` — the suite advances the loop one iteration at a time.
        let clock = MockClock()
        let bus = EventBus()
        let configuration = ConvertConfiguration(
            sdkKey: "test-key",
            dataRefreshIntervalMs: refreshIntervalMs
        )
        let sdk = ConvertSDK(
            configuration: configuration,
            configProvider: fetch,
            eventBus: bus,
            clock: clock
        )
        return WiringSUT(sdk: sdk, fetch: fetch, clock: clock, bus: bus)
    }

    // MARK: - Scenario 1 — the scheduler starts after ready() and an interval tick re-fetches

    /// PLAT-2 core contract: after the SDK initializes and `ready()` resolves, the refresh
    /// scheduler is RUNNING — one interval tick drives an ADDITIONAL `fetchLiveConfig()` beyond the
    /// init's own fetch.
    ///
    /// Sequence: `ready()` (the init's cache-miss → live-fetch → `setConfig` chain completed) →
    /// `waitForFetchCount(1)` (a real happens-before on the init's OWN fetch) → `clock.tick()`
    /// (release one interval sleep) → `waitForFetchCount(2)` (the scheduler's first interval
    /// refresh). The credit-banking `MockClock` makes the tick safe even if issued before the
    /// scheduler parked on its first `sleep` (the credit is consumed by that `sleep`); the
    /// `waitForFetchCount(2)` await is the authoritative happens-before, so the assertion is
    /// 0-flake under parallel load. Reaching a 2nd fetch is the proof the scheduler is wired and
    /// running post-ready — without the wiring the count would stay at 1 and `waitForFetchCount(2)`
    /// would hang (surfacing the missing wiring, not a false pass).
    @MainActor
    @Test("the scheduler starts after ready() and an interval tick drives an additional fetch")
    func schedulerStartsAfterReadyAndIntervalTickRefetches() async throws {
        let sut = try makeWiringSut()
        try await sut.sdk.ready()

        // The init's own live fetch (#1) — await it as a genuine happens-before before ticking, so
        // the scheduler is constructed and the interval loop is the only thing left to drive.
        await sut.fetch.waitForFetchCount(1)

        // Release one interval sleep; the scheduler's interval loop runs ONE iteration and refetches.
        sut.clock.tick()
        await sut.fetch.waitForFetchCount(2)

        #expect(await sut.fetch.fetchLiveConfigCallCount >= 2)
    }

    // MARK: - Scenario 2 — the interval refresh fires .configUpdated through the SDK's bus

    /// PLAT-2 contract (observable side): the scheduler's interval refresh writes the fresh config
    /// to the SDK's `ConfigStore`, and because the store is already READY (the init's first
    /// `setConfig` latched it), that write is a POST-READY refresh — firing `.configUpdated` on the
    /// SDK's bus. Subscribes via `sdk.on(.configUpdated)` (exercising the SDK's bus forwarding) so
    /// this asserts the wired scheduler reaches the SAME bus the SDK exposes.
    ///
    /// `countEvents` + `drainMainActor` are reused from `TestFixtures.swift` (the same shape
    /// `ConfigStoreTests` / `ConfigRefreshSchedulerTests` use): the counter subscribes a `@Sendable`
    /// observer; `EventBus.fire` delivers each callback as a `MainActor` task, so `drainMainActor()`
    /// (a serial-executor barrier, NOT `Task.yield()`) flushes the delivery before `firings` is
    /// read. The fetch happens-before (`waitForFetchCount(2)`) orders the refresh's `setConfig`
    /// BEFORE the drain, so the `.configUpdated` it fires is delivered by the time `firings` is read.
    @MainActor
    @Test("an interval refresh fires .configUpdated on the SDK's bus")
    func schedulerObservesConfigUpdatedOnIntervalRefresh() async throws {
        let sut = try makeWiringSut()
        try await sut.sdk.ready()
        await sut.fetch.waitForFetchCount(1)

        // Subscribe through the SDK's public bus-forwarding seam AFTER ready (the init's first
        // `setConfig` fired `.ready`, not `.configUpdated`, so no refresh event has been missed).
        let updates = await countEvents(.configUpdated, on: sut.bus)

        // Drive one interval iteration; await the scheduler's refresh fetch landing (a real
        // happens-before), then flush the `MainActor` `.configUpdated` delivery it triggered.
        sut.clock.tick()
        await sut.fetch.waitForFetchCount(2)
        await drainMainActor()

        #expect(updates.firings >= 1)

        await sut.bus.off(updates.token)
    }
}
