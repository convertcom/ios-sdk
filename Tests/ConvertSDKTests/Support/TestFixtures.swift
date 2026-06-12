// Tests/ConvertSDKTests/Support/TestFixtures.swift
//
// Shared RED-phase fixtures for the `ConfigRefreshScheduler` suite (Epic 2 / Story 4 —
// foreground config refresh + Low-Power-Mode pause). This file is a TEST-SUPPORT file:
// everything here EXCEPT the `ConfigRefreshScheduler` references in `makeSchedulerSut`'s
// return type compiles today. The scheduler type does NOT exist yet (the GREEN step
// creates `actor ConfigRefreshScheduler` at `Sources/ConvertSDK/Lifecycle/ConfigRefreshScheduler.swift`),
// so this file — and the suite that uses it — fails to compile with "cannot find type
// 'ConfigRefreshScheduler' in scope", which is the expected RED state for this TDD cycle.
//
// ── Why a REAL ConfigStore (not a MockConfigStore) ─────────────────────────────────────────
// The scheduler calls `configStore.setConfig(fresh)` on a successful refresh. To assert
// "setConfig was / was NOT called" WITHOUT inventing a `MockConfigStore`, the factory uses the
// REAL `ConfigStore`, PRE-READIED (when `cachedReady`) by an initial `setConfig(makeRefreshConfig())`.
// Because `ConfigStore.setConfig` fires `.configUpdated` ONLY on a POST-READY call (the first call
// latches `.ready` instead — see `ConfigStoreTests`), a refresh after pre-ready is observable as a
// SINGLE `.configUpdated` on the shared `EventBus`, and the new snapshot is readable via
// `getSnapshot()`. A failed refresh (live == nil) must NOT call `setConfig`, so the store still
// holds the pre-ready snapshot and NO further `.configUpdated` fires — exactly the negative the
// failure tests assert. This reuses the contract `ConfigStoreTests` already locked; it invents no
// new store double.
//
// ── Notification delivery is via a FRESH NotificationCenter (parallel-safe) ─────────────────
// Every SUT gets its OWN `NotificationCenter()` (NOT `.default`), so foreground / power-state
// notifications posted by one test never leak into another running in parallel. The scheduler's
// observers (`notifications(named:)`) are wired to that same fresh center via the init parameter.
import Testing
import Foundation
@testable import ConvertSDK

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - MockConfigFetchService

/// Counting test double for ``ConfigProviding`` used by the scheduler suite — it records how
/// many times the scheduler fetched (the loop / foreground / LPM-exit triggers) and lets a test
/// flip the live result to `nil` to simulate a failed refresh.
///
/// Shape: `actor` — ``ConfigProviding`` refines `Sendable` and BOTH requirements are `async`, so
/// actor isolation satisfies the protocol with NO `Sendable` suppression (mirrors
/// ``MockHTTPClient`` / ``MockConfigProvider``). Distinct from ``MockConfigProvider`` (which models
/// the init-time cached/live matrix and a one-shot gate): this double's job is CALL COUNTING for
/// the refresh loop, plus a mutable `live` the test can null out mid-run.
actor MockConfigFetchService: ConfigProviding {
    /// The config ``fetchLiveConfig()`` returns. Mutable so a test can flip it to `nil`
    /// (``setLive(_:)``) to drive the failed-refresh path after construction.
    private var live: ProjectConfig?
    /// The config ``loadCachedConfig()`` returns (the scheduler does not call this on the refresh
    /// path, but the double honors the full port so it is reusable).
    private let cached: ProjectConfig?
    private var fetchCount = 0
    private var loadCachedCount = 0
    /// Awaiters parked by ``waitForFetchCount(_:)``, each keyed to the fetch-count THRESHOLD it is
    /// waiting for. ``fetchLiveConfig()`` resumes (and removes) every awaiter whose threshold the
    /// new count has reached. A named struct keeps the `large_tuple` lint rule satisfied.
    private struct FetchAwaiter {
        let threshold: Int
        let continuation: CheckedContinuation<Void, Never>
    }
    private var fetchAwaiters: [FetchAwaiter] = []

    init(cached: ProjectConfig? = nil, live: ProjectConfig?) {
        self.cached = cached
        self.live = live
    }

    /// How many times ``fetchLiveConfig()`` has been invoked — the core refresh-count assertion.
    var fetchLiveConfigCallCount: Int { fetchCount }

    /// How many times ``loadCachedConfig()`` has been invoked.
    var loadCachedConfigCallCount: Int { loadCachedCount }

    /// Suspends until ``fetchLiveConfig()`` has been CALLED at least `target` times, then resumes — a
    /// genuine happens-before on "the Nth fetch has run", replacing the bounded `drainUntil` poll
    /// that RACED the detached `Task` a `NotificationCenter` foreground/power-state block (or the
    /// interval-loop continuation) spawns to perform the fetch. Returns immediately if the count is
    /// already ≥ `target`; otherwise parks a continuation keyed to that threshold, which
    /// ``fetchLiveConfig()`` resumes the instant the count reaches it. A pure continuation handoff —
    /// no wall-clock wait (NFR21) — mirroring ``MockConfigProvider``'s gate and the
    /// ``ConfigStore/waitForReady()`` pattern. ONLY use for a count that WILL be reached; a
    /// threshold that never arrives (e.g. the within-TTL second attempt that is correctly SKIPPED)
    /// would park forever — those tests await the skip log via ``MockLogger/waitForEntry`` instead.
    func waitForFetchCount(_ target: Int) async {
        if fetchCount >= target { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            fetchAwaiters.append(FetchAwaiter(threshold: target, continuation: continuation))
        }
    }

    /// Replaces the live result (e.g. flip to `nil` to simulate a network/decode failure on the
    /// NEXT fetch).
    func setLive(_ config: ProjectConfig?) {
        live = config
    }

    func loadCachedConfig() async -> ProjectConfig? {
        loadCachedCount += 1
        return cached
    }

    func fetchLiveConfig() async -> ProjectConfig? {
        fetchCount += 1
        // Resume (and drop) every awaiter whose threshold the new count has now reached. Actor
        // isolation is the mutual exclusion here, so the continuations are resumed directly — there
        // is no lock to step outside of (unlike the `final class` mocks). Each parked continuation
        // is resumed exactly once because it is removed from `fetchAwaiters` as it is collected.
        let ready = fetchAwaiters.filter { $0.threshold <= fetchCount }
        fetchAwaiters.removeAll { $0.threshold <= fetchCount }
        for awaiter in ready {
            awaiter.continuation.resume()
        }
        return live
    }
}

// MARK: - Foreground notification name (platform-conditional)

/// The notification name the scheduler's foreground observer watches, per platform: the UIKit
/// `willEnterForeground` on iOS/tvOS, the AppKit `willBecomeActive` on macOS. `nil` on a platform
/// with neither (the foreground test is then skipped). Centralized so the SUT factory, the
/// `triggerForeground` helper, and the test all name the SAME notification — production and test
/// share one source of truth for the platform-conditional name.
enum ForegroundNotification {
    /// The platform foreground notification name, or `nil` where no app-lifecycle center exists.
    static var name: Notification.Name? {
        #if canImport(UIKit)
        return UIApplication.willEnterForegroundNotification
        #elseif canImport(AppKit)
        return NSApplication.willBecomeActiveNotification
        #else
        return nil
        #endif
    }
}

// MARK: - ProjectConfig builder

/// Builds a valid, minimal ``ProjectConfig`` by decoding a tiny wire payload carrying `accountId`.
///
/// Single source of the decode literal so no scheduler test re-inlines it (SonarQube
/// new-duplicated-lines gate; CPD is token-based, so the shared literal — not the variable names —
/// is what keeps the diff under the threshold). The JSON mirrors `ConfigStoreTests.makeConfig` and
/// `ConvertSDKTests.makeConfig`; `ProjectConfig` decodes field-by-field and never throws on this
/// shape, so `try` is satisfied without a fixture file. `accountId` defaults so the common case
/// needs no argument, and the identity is assertable when a test must distinguish snapshots.
///
/// Named `makeRefreshConfig` (not `makeValidConfig`) ON PURPOSE: `ConvertSDKTests.swift` already
/// declares a file-private `makeValidConfig()` (no args). A same-named internal helper here would
/// make a bare `makeValidConfig()` call in that file an ambiguous overload — so this scheduler-suite
/// builder gets a distinct name and cannot collide.
func makeRefreshConfig(accountId: String = "acc-refresh") throws -> ProjectConfig {
    try JSONDecoder().decode(
        ProjectConfig.self,
        from: Data(#"{"account_id":"\#(accountId)","project":{"id":"p-1"}}"#.utf8)
    )
}

/// Sentinel marking the `live` argument of `makeSchedulerSut(...)` as OMITTED — distinct from an
/// explicit `live: nil` (which the failure suites pass to force a failing fetch).
///
/// Why a sentinel, not a plain `nil` default: a defaulted `ProjectConfig?` parameter cannot tell
/// "caller omitted `live`" from "caller passed `live: nil`" — Swift makes BOTH the value `nil`, so
/// the success suites (which omit `live` and expect a real `acc-live` config) and the failure suites
/// (which pass `live: nil` and expect a `nil` fetch) would be indistinguishable. (The double-optional
/// `ProjectConfig??` idiom does NOT help: Swift collapses a passed `nil` onto the OUTERMOST optional,
/// so `live: nil` still binds to the same case as omission — verified.) A sentinel value carrying a
/// reserved ``ProjectConfig/accountId`` that no real or test config uses lets the factory branch on
/// identity-by-id: the sentinel means "omitted → use the default `acc-live`", any other value
/// (including an explicit `nil`) is honored verbatim. Built with `try?` (never actually nil here:
/// ``makeRefreshConfig(accountId:)`` does not throw on this static literal — see its doc), and even
/// an impossible `nil` would only mean an omitted `live` is treated as a failing fetch, never the
/// reverse, so the sentinel cannot silently corrupt the success path.
private let omittedLiveSentinelAccountId = "__omitted_live_sentinel__"
private let omittedLiveSentinel: ProjectConfig? = try? makeRefreshConfig(accountId: omittedLiveSentinelAccountId)

// MARK: - Scheduler SUT factory

/// The fully-wired scheduler system-under-test plus every collaborator a test needs to drive and
/// observe it. A named struct (not a large tuple) keeps the `large_tuple` lint rule satisfied and
/// lets tests read collaborators by name. `Sendable` — every member is `Sendable` (four actors, a
/// `MockLogger`/`MockClock`/`LockedBox` built on the audited lock primitive, and `NotificationCenter`)
/// — so a `@Sendable` `drainUntil` predicate may capture the SUT without a data-race warning.
struct SchedulerSUT: Sendable {
    /// The system under test (does not exist until GREEN — this is the RED-making reference).
    let scheduler: ConfigRefreshScheduler
    /// The counting fetch double; read `fetchLiveConfigCallCount` to assert refreshes.
    let fetch: MockConfigFetchService
    /// The REAL config store the scheduler writes to on a successful refresh.
    let store: ConfigStore
    /// The bus the store fires `.configUpdated` on; subscribe to observe (or not) a store write.
    let bus: EventBus
    /// The structured-log spy; `entries(...)` filters the lines the scheduler emitted.
    let logger: MockLogger
    /// The stepping clock; call `tick()` to advance the interval loop one iteration, `setNow(_:)`
    /// to move TTL time directly.
    let clock: MockClock
    /// The FRESH notification center the scheduler observes; post foreground / power-state
    /// notifications here to trigger the observers in isolation.
    let center: NotificationCenter
    /// The mutable cell the `powerModeProvider` closure reads; flip via `setPowerMode(_:)` to
    /// simulate entering / leaving Low Power Mode after construction.
    let powerModeCell: LockedBox<Bool>

    /// Flips the simulated Low-Power-Mode state the scheduler's `powerModeProvider` reads.
    func setPowerMode(_ enabled: Bool) {
        powerModeCell.set(enabled)
    }
}

/// Builds a `ConfigRefreshScheduler` SUT wired to counting / observable collaborators.
///
/// `async` because pre-readying the REAL `ConfigStore` (so a later refresh fires `.configUpdated`
/// rather than the one-shot `.ready`) requires awaiting an initial `setConfig` — the await is a
/// fixture-setup hop, NOT a wall-clock wait (NFR21). The clock defaults to a fresh STEPPING
/// `MockClock` (`autoAdvance: false`) so the interval loop advances only when a test calls
/// `clock.tick()`; the center defaults to a fresh isolated `NotificationCenter()`.
///
/// - Parameters:
///   - cachedReady: pre-ready the store with a valid config so a scheduler refresh is observable as
///     a `.configUpdated` (and `getSnapshot()` identity changes). `false` leaves the store pending.
///   - live: the config the fetch double returns. OMIT it for a successful refresh (a fresh
///     `acc-live` config is supplied); pass an explicit `live: nil` to simulate a FAILING refresh.
///     The default is the ``omittedLiveSentinel`` (NOT `nil`), so an explicit `nil` is distinguishable
///     from omission — see that sentinel's doc for why a plain `nil` default cannot tell them apart.
///   - powerMode: the INITIAL Low-Power-Mode state the `powerModeProvider` reports.
///   - refreshIntervalMs: the interval the scheduler sleeps between loop ticks.
func makeSchedulerSut(
    cachedReady: Bool = true,
    live: ProjectConfig? = omittedLiveSentinel,
    powerMode: Bool = false,
    refreshIntervalMs: Int = Defaults.dataRefreshIntervalMs,
    clock: MockClock = MockClock(),
    center: NotificationCenter = NotificationCenter()
) async throws -> SchedulerSUT {
    // The fetch double's live result: OMITTED `live` (the sentinel, matched by its reserved
    // accountId) → a fresh valid config carrying a distinct accountId so a refresh is a genuine
    // snapshot change. An explicitly-passed `live` (incl. an intentional `nil` for the failure
    // suites) is honored verbatim — a `nil` here drives the failing-refresh path.
    let liveConfig: ProjectConfig? = try {
        if live?.accountId == omittedLiveSentinelAccountId {
            return try makeRefreshConfig(accountId: "acc-live")
        }
        return live
    }()
    let fetch = MockConfigFetchService(live: liveConfig)

    let bus = EventBus()
    let store = ConfigStore(eventBus: bus)
    if cachedReady {
        // Latch the store READY with a DISTINCT pre-ready config so a subsequent refresh is an
        // observable `.configUpdated` (the post-ready branch), and so the snapshot's accountId
        // distinguishes "still pre-ready" (failure) from "refreshed" (success).
        await store.setConfig(try makeRefreshConfig(accountId: "acc-cached"))
    }

    let logger = MockLogger()
    let powerModeCell = LockedBox<Bool>(powerMode)
    let scheduler = ConfigRefreshScheduler(
        configStore: store,
        fetchService: fetch,
        logger: logger,
        clock: clock,
        powerModeProvider: { powerModeCell.get },
        notificationCenter: center,
        refreshIntervalMs: refreshIntervalMs
    )

    return SchedulerSUT(
        scheduler: scheduler,
        fetch: fetch,
        store: store,
        bus: bus,
        logger: logger,
        clock: clock,
        center: center,
        powerModeCell: powerModeCell
    )
}

// MARK: - Notification triggers

/// Posts the platform foreground notification to `center`, driving the scheduler's foreground
/// observer. A no-op on a platform with no foreground notification (the foreground test guards on
/// the same condition and is skipped there). Posts the SAME name (`ForegroundNotification.name`)
/// the SUT factory wired the observer to — one source of truth for the name.
func triggerForeground(center: NotificationCenter) {
    guard let name = ForegroundNotification.name else { return }
    center.post(name: name, object: nil)
}

/// Posts the power-state-changed notification to `center`, driving the scheduler's power-state
/// observer (the handler re-reads the `powerModeProvider`, so flip the SUT's power-mode cell BEFORE
/// posting). The Swift name is `Notification.Name.NSProcessInfoPowerStateDidChange` (the imported
/// form of ObjC `NSProcessInfoPowerStateDidChangeNotification`, `API_AVAILABLE(macos(12.0),
/// ios(9.0), watchos(2.0), tvos(9.0))` — verified against the SDK headers). It is genuinely
/// cross-platform (NOT a UIKit symbol), so the LPM-exit test runs on every host the package targets
/// — no `#if` guard. NOTE for GREEN: the scheduler must observe this SAME Swift name; the Story 2.4
/// `ProcessInfo.powerStateDidChangeNotification` / `NSProcessInfo.powerStateDidChangeNotification`
/// sketches are not the correct Swift spelling.
func triggerPowerStateChange(center: NotificationCenter) {
    center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
}

// MARK: - Event observation

/// A live count of how many times a given `SystemEvent` fired on a bus, plus the token to stop
/// observing. A named struct (not a tuple) keeps the `large_tuple` rule satisfied. The count cell
/// is a ``LockedBox`` so the `@Sendable` bus callback can mutate it data-race-free; tests read it
/// via `firings` AFTER draining the `MainActor` callback queue. (Named `firings`, not `count`, so
/// an `== 0` check reads as a scalar comparison and does not trip the `empty_count` lint rule,
/// which would wrongly push `isEmpty` onto a plain `Int`.)
struct EventCounter {
    /// The lock-guarded firing count; read after a `MainActor` drain.
    let box: LockedBox<Int>
    /// The subscription token; pass to `bus.off(_:)` to stop counting.
    let token: EventListenerToken

    /// The number of deliveries observed so far (read after draining the `MainActor` queue).
    var firings: Int { box.get }
}

/// Subscribes a counting observer for `event` on `bus` and returns the live counter. Single owner
/// of the subscribe-and-count wiring so the interval / config-updated / failure suites do not each
/// re-inline a `bus.on(_:) { box.withLock { $0 += 1 } }` block (SonarQube new-duplicated-lines
/// gate). `EventBus.fire` delivers each callback as a `MainActor` task, so the caller must drain
/// the `MainActor` queue (e.g. `await drainMainActor()`) before reading `counter.count`.
func countEvents(_ event: SystemEvent, on bus: EventBus) async -> EventCounter {
    let box = LockedBox<Int>(0)
    let token = await bus.on(event) { _ in box.withLock { $0 += 1 } }
    return EventCounter(box: box, token: token)
}

// MARK: - Deterministic delivery drain (no wall-clock wait)

/// Lets already-dispatched `MainActor` callbacks (the `EventBus.fire` deliveries) run before a
/// test reads an ``EventCounter``. Awaiting `MainActor.run { }` enqueues a barrier behind the
/// already-hopped callback jobs; the serial `MainActor` executor runs it only after every prior
/// callback. A pure executor barrier, NOT a wall-clock wait (NFR21). Mirrors the `drain()` in
/// `EventBusTests` / `ConfigStoreTests` / `ConvertSDKTests`.
func drainMainActor() async {
    await MainActor.run { }
}

/// Bounded executor-barrier drain: drives a `MainActor` executor hop up to `maxRounds` times,
/// breaking as soon as `condition` holds. Used to let a notification observer deliver and the
/// scheduler act on it (its async refresh attempt: fetch → store write OR WARN log), WITHOUT a
/// wall-clock sleep (NFR21). This is a DELIVERY DRAIN — it asserts nothing about elapsed time; it
/// only gives the runtime turns to run already-enqueued work, then the CALLER asserts. The bound
/// prevents a runaway loop if the awaited effect never happens (the subsequent `#expect` then fails
/// loudly rather than hanging).
///
/// Each round hops the SERIAL `MainActor` executor (via ``drainMainActor()``), NOT a bare
/// `Task.yield()`. `Task.yield()` reschedules THIS task on the cooperative pool and does not
/// reliably give a DIFFERENT actor's already-enqueued continuation a turn — so when the awaited
/// effect is the tail of the scheduler actor's refresh attempt (e.g. the synchronous WARN log that
/// runs one continuation AFTER the awaited `fetchLiveConfig()` returns), a yield-only drain can spend
/// its whole budget before that continuation is scheduled, and the effect lands only after the
/// assertion. A `MainActor.run { }` barrier forces a real suspension onto a serial executor, which
/// lets every pending continuation — including the scheduler's — get scheduled before the next
/// round, making notification-driven effects observable deterministically. It remains a pure
/// executor barrier, never a wall-clock wait (NFR21).
func drainUntil(maxRounds: Int = 200, _ condition: @Sendable () async -> Bool) async {
    for _ in 0..<maxRounds {
        if await condition() { return }
        await drainMainActor()
    }
}
