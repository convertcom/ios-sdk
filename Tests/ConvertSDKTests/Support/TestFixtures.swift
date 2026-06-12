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
//
// `file_length` is disabled file-wide (a single named rule — NOT `disable all`): this is the shared
// fixture file for BOTH the scheduler RED suite and the Story 3.5 `runExperiences` wiring suite, and it
// sat at exactly the 400-line default before the multi-experience fixture was added. Splitting these
// co-located fixtures across files to shave a handful of lines would scatter the test-support surface
// for no readability gain; all other rules remain enforced. (Mirrors `OpenAPIRuntimeShim.swift`'s
// file-wide `file_length` disable convention.)
// swiftlint:disable file_length
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

/// A valid ``ProjectConfig`` carrying exactly ONE 100%-traffic experience — the fixture the Story 3.4
/// `runExperience` WIRING suite (``ConvertContextRunExperienceTests``) buckets through. Decodes the
/// SAME wire shape `ProjectConfigFixtures.experienceJSON` pins for `ExperienceManagerTests`:
/// `account_id` / `project.id` present (so the sticky store key `"<accountId>-<projectId>-<visitorId>"`
/// is well-formed) and one `type:"a/b"` experience with a sole `traffic_allocation:100` variation.
/// That sole variation maps to weight `100 × 100 == 10000`, covering the entire `0..<10000` bucket
/// space, so `selectBucket` returns it for EVERY visitor hash — `runExperience(experienceKey)` against
/// the REAL wiring deterministically resolves THIS variation (`id == variationId`, `experienceKey ==
/// experienceKey`) regardless of `visitorId`, which is why the wiring tests assert a CONCRETE id, not
/// merely non-nil. Re-declared here (not reaching `ConvertSDKCoreTests`' identical `ProjectConfigFixtures`,
/// which compiles into the OTHER target and is invisible across the boundary); the decode literal is
/// written ONCE and shared by every wiring test (SonarQube 3% new-duplicated-lines gate; CPD is
/// token-based, so the shared builder — not renamed locals — holds the diff under it). `throws` only on
/// malformed JSON (`ProjectConfig.init(from:)` degrades per-field). `experienceKey` is what
/// `runExperience(_:)` looks up; `variationId` is the id the resolved variation carries.
func makeExperienceConfig(
    experienceKey: String,
    variationId: String,
    variationKey: String,
    experienceId: String = "exp-1"
) throws -> ProjectConfig {
    // Assembled in fragments (variation → experience → envelope) so each line stays ≤120 chars.
    let variation = #"{"id":"\#(variationId)","key":"\#(variationKey)","traffic_allocation":100}"#
    let experienceHead = #"{"id":"\#(experienceId)","key":"\#(experienceKey)","type":"a/b","#
    let experience = experienceHead + #""audiences":[],"locations":[],"variations":[\#(variation)]}"#
    let envelope = #"{"account_id":"acc-run","project":{"id":"proj-run"},"experiences":[\#(experience)]}"#
    return try JSONDecoder().decode(ProjectConfig.self, from: Data(envelope.utf8))
}

/// One experience-wire FRAGMENT (no envelope) for the 1-based `index`: a `type:"a/b"`, no-audience,
/// no-location experience keyed `"exp-{index}"` (id `"exp-{index}"`) with a sole `traffic_allocation:100`
/// variation (id `"var-{index}"`). SAME shape `makeExperienceConfig` embeds, so the multi builder
/// composes THIS per index rather than re-inlining the experience literal (SonarQube 3% gate; CPD is
/// token-based, so one shared fragment holds the diff under it). Joined into `experiences` by
/// ``makeMultiExperienceConfig``.
private func experienceFragment(index: Int) -> String {
    let variation = #"{"id":"var-\#(index)","key":"control","traffic_allocation":100}"#
    let head = #"{"id":"exp-\#(index)","key":"exp-\#(index)","type":"a/b","#
    return head + #""audiences":[],"locations":[],"variations":[\#(variation)]}"#
}

/// A ``ProjectConfig`` with `count` 100%-traffic no-audience experiences keyed `"exp-1".."exp-{count}"`,
/// in DETERMINISTIC config order — the multi-experience twin of ``makeExperienceConfig`` used by the
/// Story 3.5 `runExperiences` WIRING suite. Each experience runs for everyone (no audience) and its sole
/// full-traffic variation covers the whole `0..<10000` bucket space ⇒ buckets EVERY visitor, so a ready
/// SDK resolves `runExperiences()` to EXACTLY `count` variations with `experienceKey`s `["exp-1", …]` in
/// order — which is why the wiring tests assert a concrete count + order. Composes
/// ``experienceFragment(index:)`` per index into ONE envelope (the envelope literal written ONCE, never
/// duplicated per experience); shared `account_id`/`project.id` match ``makeExperienceConfig``. `throws`
/// only on malformed JSON (`ProjectConfig.init(from:)` degrades per-field, so this shape never throws).
func makeMultiExperienceConfig(count: Int) throws -> ProjectConfig {
    let experiences = (1...count).map(experienceFragment(index:)).joined(separator: ",")
    let envelope = #"{"account_id":"acc-run","project":{"id":"proj-run"},"experiences":[\#(experiences)]}"#
    return try JSONDecoder().decode(ProjectConfig.self, from: Data(envelope.utf8))
}

/// A ``ProjectConfig`` carrying ONE feature plus the experience that enables it — the fixture the
/// Story 4.1 `runFeature`/`runFeatures` WIRING suite (``ConvertContextRunFeaturesTests``) resolves
/// through. Built so a READY SDK buckets EVERY visitor into the carrier and the feature comes back
/// `.enabled` with two typed variables (`flag: Bool == true`, `label: String == "hi"`):
///   * ONE `type:"a/b"` experience (id `"feat-exp"`, key `"feat-exp-key"`, no audiences/locations so
///     the gates are bypassed) whose SOLE `traffic_allocation:\#(alloc)` variation (id `"feat-var"`,
///     key `"feat-var-key"`) carries ONE `fullStackFeature` change. `alloc:100` (the default) ⇒ the
///     variation covers the whole `0..<10000` bucket space ⇒ buckets for EVERY visitor hash, so the
///     feature is enabled regardless of `visitorId`.
///   * A top-level `features` array with ONE entry whose STRING `id` is `String(featureIdInt)` and
///     whose `variables` declare the two types the feature path reads to type `variables_data`.
///
/// ── The change `id` MUST be an INTEGER (load-bearing trap) ──────────────────────────────────────
/// `ExperienceChangeIdReadOnly.id` is `Swift.Int?` ("the unique numerical identifier"). The change is
/// written `{"id":1,"type":"fullStackFeature",…}` — an INTEGER, NOT a quoted string. A string id makes
/// the FULL ``ConfigExperience`` decode throw `typeMismatch`, which silently degrades the whole
/// experience out of `ProjectConfig.rawExperiences` (the per-element `try?`), so its variation can
/// never carry the feature and the feature can never enable. This was already discovered and fixed in
/// the core-target fixture (`ProjectConfigFixtures.fullStackFeatureExperienceJSON`); this builder
/// mirrors that exact wire shape.
///
/// ── The cross-type binding ───────────────────────────────────────────────────────────────────────
/// The change's `data.feature_id` is the INT `\#(featureIdInt)` while `features[].id` is the STRING
/// `String(featureIdInt)`; `FeatureManager` binds them via `String(feature_id) == feature.id`, so the
/// integer change value and the quoted feature id are deliberately the SAME number in two types. The
/// variable VALUES live in the change's `variables_data`; their TYPES come from `features[].variables`.
///
/// Re-declared here (not reaching `ConvertSDKCoreTests`' `ProjectConfigFixtures`, which compiles into
/// the OTHER target and is invisible across the boundary). Assembled in fragments (variation → change
/// → experience → envelope) so each line stays ≤120 chars (SwiftLint `line_length`); `account_id` /
/// `project.id` are `"acc-run"` / `"proj-run"` to match the other run-* builders. `throws` only on
/// malformed JSON (`ProjectConfig.init(from:)` degrades per-field, so this shape never throws).
///
/// - Parameters:
///   - featureKey: The feature's `key` — what `runFeature(_:)` looks up (default `"flag-1"`).
///   - featureIdInt: The feature id as an INT; the feature's wire `id` is its string form, and the
///     change's `feature_id` is this same integer (default `10031`).
///   - alloc: The carrier variation's 0–100 traffic percentage (`100` ⇒ always buckets ⇒ enabled).
func makeFeatureConfig(
    featureKey: String = "flag-1",
    featureIdInt: Int = 10031,
    alloc: Int = 100
) throws -> ProjectConfig {
    // The variable VALUES (in the change) and their declared TYPES (in `features[].variables`) — the
    // feature path joins the two by name, yielding `flag: Bool == true` and `label: String == "hi"`.
    let variablesData = #"{"flag":true,"label":"hi"}"#
    let variableTypes = #"[{"key":"flag","type":"boolean"},{"key":"label","type":"string"}]"#
    // INTEGER change id (the trap above): a quoted id degrades the whole experience out of rawExperiences.
    let changeData = #""data":{"feature_id":\#(featureIdInt),"variables_data":\#(variablesData)}"#
    let change = #"{"id":1,"type":"fullStackFeature",\#(changeData)}"#
    let variationHead = #"{"id":"feat-var","key":"feat-var-key","traffic_allocation":\#(alloc),"#
    let variation = variationHead + #""changes":[\#(change)]}"#
    let experienceHead = #"{"id":"feat-exp","key":"feat-exp-key","type":"a/b","#
    let experience = experienceHead + #""audiences":[],"locations":[],"variations":[\#(variation)]}"#
    let featureHead = #"{"id":"\#(featureIdInt)","name":"\#(featureKey)-name","key":"\#(featureKey)","#
    let feature = featureHead + #""variables":\#(variableTypes)}"#
    let envelopeHead = #"{"account_id":"acc-run","project":{"id":"proj-run"},"#
    let envelope = envelopeHead + #""experiences":[\#(experience)],"features":[\#(feature)]}"#
    return try JSONDecoder().decode(ProjectConfig.self, from: Data(envelope.utf8))
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
