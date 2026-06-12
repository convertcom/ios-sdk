// ConvertSDK.swift
// Public entry point for the Convert iOS SDK (Epic 2 / Story 2).
// Re-exports ConvertSDKCore so consumers need only `import ConvertSDK`.
//
// `file_length` is disabled file-wide (a single named rule — NOT a blanket `disable all`): this is the
// SDK's public-surface composition root, and its DocC-heavy house style (each public member + the
// wiring decisions carry full rationale) pushed it past the 400-line default once Story 5.1 wired the
// real `EventQueue` into both the conversion and bucketing seams (the `resolveEventSink` helper and its
// rationale). Trimming the mandated rationale to chase the line count would trade documentation rigor
// for a cosmetic number; the named-rule suppression keeps every other rule — and the 400-line gate on
// every OTHER file — enforced. Mirrors the same documented suppression on `ConvertContext.swift`.
// swiftlint:disable file_length

@_exported import ConvertSDKCore
import Foundation

/// The public entry point and handle for the Convert iOS SDK.
///
/// Constructed synchronously (the initializer never blocks): config loading runs in a
/// detached `Task`, and `ready()` suspends until that load resolves — successfully, degraded
/// (transient network failure), or with an unrecoverable configuration error. The handle is a
/// `Sendable` `final class`: every stored property is an immutable `let` of a `Sendable` type
/// (a value struct or an actor), so the compiler proves data-race safety with NO
/// `@unchecked Sendable`.
public final class ConvertSDK: Sendable {
    /// The immutable configuration this handle was created with.
    private let configuration: ConvertConfiguration
    /// The bus on which `.ready` (and later system events) fire; shared with ``configStore``.
    private let eventBus: EventBus
    /// Owns the "config present" state and the one-shot ready gate.
    ///
    /// internal (not private): the test target reaches configStore.getSnapshot() to assert
    /// snapshot retention across the cache→live sequence.
    internal let configStore: ConfigStore
    /// Pre-fetched config payload for the direct-data initializer; `nil` on the key path.
    private let directData: Data?
    /// Owns the lazily-started ``ConfigRefreshScheduler``. A `let` reference to a `Sendable` actor:
    /// the box (not this class) holds the mutable scheduler, so this stays an all-`let` `Sendable`
    /// `final class` with no suppression. The detached load `Task` sets it after the first config
    /// lands (key path only — the directData path returns before provider resolution and never
    /// starts a scheduler); ``deinit`` cancels through it.
    private let schedulerBox = SchedulerBox()

    /// The secure (Keychain) store ``createContext`` hands to ``VisitorContextManager`` for visitor-ID
    /// persistence. Injectable (the production default is ``KeychainSecureStore``; tests inject a mock
    /// to assert write behaviour). The ``SecureStore`` port refines `Sendable`, so this `let` keeps the
    /// class an all-`let` `Sendable final class` with no suppression.
    private let secureStore: any SecureStore

    /// The lightweight key/value (`UserDefaults`) mirror ``createContext`` hands to
    /// ``VisitorContextManager`` for visitor-ID persistence. Injectable (the production default is
    /// ``UserDefaultsKeyValueStore``). The ``KeyValueStore`` port refines `Sendable`, so this `let`
    /// keeps the class `Sendable` with no suppression.
    private let keyValueStore: any KeyValueStore

    /// The ONE canonical ``DecisionStore`` this SDK injects into EVERY ``ConvertContext`` it creates,
    /// so all contexts from this handle share a single store (sticky variations / goal-dedup / segments
    /// converge on one instance — Stories 3.4 / 4.2). An `actor` is `Sendable`, so this `let` keeps the
    /// class `Sendable` with no suppression. Injectable so a test can assert the shared-identity contract.
    private let decisionStore: DecisionStore

    /// The ONE ``EventSink`` every ``ConvertContext`` from this handle enqueues entries through —
    /// shared by BOTH the conversion seam (Story 4.2) AND the bucketing path. In production it is the
    /// real ``EventQueue`` (Epic 5 / Story 1), built in `init` and passed to BOTH
    /// ``ExperienceManager/makeDefault(decisionStore:eventBus:logger:eventSink:)`` and every context;
    /// a test injects a `MockEventSink` (via the optional `eventSink:` init parameter) to observe the
    /// enqueue on both paths. The ``EventSink`` port refines `Sendable`, so this `let` keeps the class
    /// an all-`let` `Sendable final class` with no suppression.
    private let eventSink: any EventSink

    /// The ``Logger`` this SDK's ``createContext`` hands to ``ConvertContext`` (so a context's
    /// `trackConversion` drop paths emit observable WARNs) AND uses for the visitor-ID resolver /
    /// attribute coercion. Defaults to ``NoopLogger`` (the production logging path until a real OSLog
    /// sink ships — the same default the config-load `Task` uses); a test injects a `MockLogger` to
    /// observe the lines. The ``Logger`` port refines `Sendable`, so this `let` keeps the class an
    /// all-`let` `Sendable final class` with no suppression.
    private let logger: any Logger

    /// The single, fully-wired ``ExperienceManager`` every ``ConvertContext`` from this handle delegates
    /// `runExperience` to (Story 3.4). Built ONCE in `init` via
    /// ``ExperienceManager/makeDefault(decisionStore:eventBus:logger:)`` over the SDK's CANONICAL
    /// ``decisionStore`` (so sticky decisions read/persist on the one shared store) and SHARED
    /// ``eventBus`` (so `.bucketing` deliveries reach `sdk.on(.bucketing)` subscribers). ``ExperienceManager``
    /// is a stateless `Sendable` `struct`, so storing it as a `let` keeps the class an all-`let`
    /// `Sendable final class` with no suppression. Stored rather than rebuilt per `createContext` so the
    /// (cheap) wiring happens exactly once.
    private let experienceManager: ExperienceManager

    /// The single, fully-wired ``FeatureManager`` every ``ConvertContext`` from this handle delegates
    /// `runFeature` / `runFeatures` to (Story 4.1). Built ONCE in `init` over the SDK's canonical
    /// ``experienceManager`` (so feature bucketing reads/persists on the one shared sticky store and its
    /// `.bucketing` deliveries reach `sdk.on(.bucketing)` subscribers) with a `NoopLogger` matching the
    /// SDK's production logging path. ``FeatureManager`` is a stateless `Sendable` `struct`, so storing it
    /// as a `let` keeps the class an all-`let` `Sendable final class` with no suppression. Stored rather
    /// than rebuilt per `createContext` so the (cheap) wiring happens exactly once.
    private let featureManager: FeatureManager

    /// Developer-assigned convenience, nil until set; not a singleton and not installed by
    /// init. `nonisolated(unsafe)` because it is intended to be assigned once at app startup,
    /// not mutated concurrently (Story 2.2 Dev Notes Option A).
    nonisolated(unsafe) public static var shared: ConvertSDK?

    /// Whether config-level network tracking is enabled (`network.tracking`, FR6). Exposed
    /// `internal` so a same-module ``ConvertContext`` can gate its (future) event-enqueue calls on
    /// the toggle without making ``configuration`` public. Reads the immutable config flag set at init.
    internal var networkTrackingEnabled: Bool {
        configuration.networkTracking
    }

    /// Dependency-injecting initializer (the test seam). Stores its dependencies, creates the
    /// ``ConfigStore`` over the shared ``EventBus``, then launches the detached config-load
    /// task. Non-throwing and non-blocking — validation and the real config fetch happen in the
    /// task, and surface through `ready()`.
    /// - Parameters:
    ///   - configuration: The SDK configuration (its `sdkKey` is validated by the load task).
    ///   - configProvider: The config-fetch seam. `nil` (the default — the production path)
    ///     builds the real ``ConfigFetchService``; tests inject a mock so the load never touches
    ///     the network.
    ///   - eventBus: The bus shared with the ``ConfigStore``; defaults to a fresh bus.
    ///   - directData: A pre-fetched config payload for the direct-data path; `nil` (the
    ///     default) selects the key path. When present, the load task validates the data
    ///     instead of fetching.
    ///   - clock: The injectable time source the refresh scheduler drives its interval loop and
    ///     TTL gate from. Defaults to ``SystemClock`` (the production wall clock); the wiring suite
    ///     injects a stepping clock so an interval tick is deterministic (NFR21). NOT stored — it is
    ///     captured by the load `Task` that constructs the scheduler.
    ///   - secureStore: The Keychain-backed visitor-ID store handed to ``VisitorContextManager`` in
    ///     ``createContext(visitorId:attributes:)``. Defaults to ``KeychainSecureStore`` (production);
    ///     the visitor-identity suite injects a mock to assert write behaviour.
    ///   - keyValueStore: The `UserDefaults`-backed visitor-ID mirror handed to
    ///     ``VisitorContextManager``. Defaults to ``UserDefaultsKeyValueStore`` (production).
    ///   - eventSink: The ``EventSink`` every context enqueues entries through (conversion AND
    ///     bucketing — Story 4.2 / Epic 5). `nil` (the production default) builds the real
    ///     ``EventQueue`` and uses it for BOTH paths; the tracking suites inject a `MockEventSink`
    ///     (non-`nil`) to observe the enqueue, which then also makes the bucketing path observable
    ///     since the same injected sink flows into
    ///     ``ExperienceManager/makeDefault(decisionStore:eventBus:logger:eventSink:)``.
    ///   - logger: The ``Logger`` handed to every context (so `trackConversion` drop-path WARNs are
    ///     observable) and used by ``createContext`` for visitor-ID resolution / attribute coercion.
    ///     Defaults to ``NoopLogger`` (the production logging path); the conversion-tracking suite
    ///     injects a `MockLogger`.
    ///   - decisionStore: The ONE canonical ``DecisionStore`` injected into every context this SDK
    ///     creates. Defaults to a fresh empty store; a test injects its own to assert shared identity.
    ///
    /// The body exceeds the 50-line `function_body_length` default by a small margin because it wires
    /// the SDK's full collaborator graph (config store, the resolved `EventSink`, the shared
    /// `ExperienceManager`/`FeatureManager`) AND launches the detached, non-blocking config-load `Task`
    /// inline — splitting the load `Task` into a separate method would either leak the capture
    /// discipline (the `store`/`schedulerBox`/`decisionStore` locals that keep the closure off `self`)
    /// or hide the non-blocking-init contract behind an indirection. Targeted disable on this one
    /// initializer (precedent: `ExperienceManager.selectVariation`'s `function_parameter_count` disable)
    /// rather than raising the project-wide threshold.
    internal init( // swiftlint:disable:this function_body_length
        configuration: ConvertConfiguration,
        configProvider: (any ConfigProviding)? = nil,
        eventBus: EventBus = EventBus(),
        directData: Data? = nil,
        clock: any Clock = SystemClock(),
        secureStore: any SecureStore = KeychainSecureStore(),
        keyValueStore: any KeyValueStore = UserDefaultsKeyValueStore(),
        eventSink: (any EventSink)? = nil,
        logger: any Logger = NoopLogger(),
        decisionStore: DecisionStore = DecisionStore(logger: NoopLogger(), fileStore: ApplicationSupportFileStore())
    ) {
        self.configuration = configuration
        self.eventBus = eventBus
        self.directData = directData
        self.secureStore = secureStore
        self.keyValueStore = keyValueStore
        self.decisionStore = decisionStore
        self.logger = logger
        // The durable pending-event-queue store (Story 5.2): the coordinated, atomic file adapter at
        // the production Application Support path. Built HERE in the composition root over the SDK's
        // REAL `logger` (the injected/production logger this init received — AC10: never a hardcoded
        // `NoopLogger()`), then threaded into `resolveEventSink` so its corruption WARNs surface on the
        // SAME logging path the rest of the SDK uses. The injected-mock branch of `resolveEventSink`
        // ignores it (a test sink has its own storage), which is fine.
        let eventQueueStore = CoordinatedFileEventQueueStore(
            fileURL: CoordinatedFileEventQueueStore.queueFileURL(),
            logger: logger
        )
        // Resolve the ONE EventSink shared by the conversion seam AND the bucketing path: an injected
        // mock flows into both; production builds the real `EventQueue` (see `resolveEventSink`).
        // Held in a LOCAL so it flows into BOTH `self.eventSink` and `makeDefault` below.
        let resolvedSink = ConvertSDK.resolveEventSink(
            injected: eventSink, configuration: configuration, eventBus: eventBus, store: eventQueueStore
        )
        self.eventSink = resolvedSink
        // Wire the ONE ExperienceManager every context delegates `runExperience` to, over the CANONICAL
        // decisionStore (sticky parity), the SHARED eventBus (so `.bucketing` subscribers fire), and the
        // RESOLVED sink (so the bucketing enqueue lands on the SAME queue/mock as the conversion seam).
        // `makeDefault` builds the internal RuleManager / BucketingManager(resolvedSink) inside
        // ConvertSDKCore, so this target never names those internal types. NoopLogger matches the SDK's
        // production logging path. A LOCAL first so the FeatureManager below reuses the SAME instance.
        let experienceManager = ExperienceManager.makeDefault(
            decisionStore: decisionStore, eventBus: eventBus, logger: NoopLogger(), eventSink: resolvedSink
        )
        self.experienceManager = experienceManager
        // Wire the ONE FeatureManager every context delegates `runFeature` / `runFeatures` to, over the
        // SAME ExperienceManager just built (so feature evaluation buckets through the shared sticky
        // store / event bus). NoopLogger matches the EM's production logging path above.
        self.featureManager = FeatureManager(experienceManager: experienceManager, logger: NoopLogger())
        let store = ConfigStore(eventBus: eventBus)
        self.configStore = store

        // The injected `configProvider` parameter is captured directly by the detached load `Task`
        // (it is `Sendable`); when `nil`, the real `ConfigFetchService` is built inside the task (off
        // the construction path, so init stays non-blocking).
        // Capture the scheduler box as a local so the detached `Task` closure picks up THIS (not
        // `self`) — keeping the closure off `self` for everything but the already-captured `store`.
        // `schedulerBox` is a `Sendable` actor, so it crosses into the `Task` with no data-race
        // warning. (The `clock` and `configProvider` PARAMETERS are themselves `Sendable` and are
        // captured directly — a `let x = x` rename would add nothing, so none is taken; only the
        // `self.`-property captures below need a shadowing local. The scheduler that consumes `clock`
        // is built INSIDE the Task after the first config lands, so `clock` need not be stored.)
        let schedulerBox = self.schedulerBox
        // Capture the decision store as a local so the `Task` closure picks up THIS (not `self`),
        // matching the `store`/`schedulerBox` capture discipline that keeps the closure off `self`.
        // `DecisionStore` is an `actor` (Sendable), so it crosses into the `Task` data-race-clean.
        let decisionStore = self.decisionStore
        Task {
            // Hydrate persisted sticky decisions from disk FIRST (AC5/FR50/FR51), independent of
            // config: runs on BOTH the key path AND the directData path (placed before the
            // `directData` early `return` below), since a direct-data SDK still wants its persisted
            // decisions restored. Awaited INSIDE the detached `Task`, so init stays non-blocking; the
            // store degrades to empty (it never throws) on a first-launch miss or corrupt bytes.
            await decisionStore.loadFromDisk()
            // Cold-start recovery (Story 5.2 / AC5 / FR37): drain any events the previous process persisted
            // to disk back into the in-memory buffer and arm the release timer, so they deliver on the next
            // flush cycle. Runs on BOTH the key path and the directData path (before the directData return),
            // since a persisted queue must be recovered regardless of how config is sourced. The downcast is
            // the production EventQueue (the injected test sink is a MockEventSink and is correctly skipped).
            if let eventQueue = resolvedSink as? EventQueue {
                await eventQueue.start()
            }
            if let directData {
                // Direct-data path: validate the payload (empty/invalid → ready() throws).
                await store.validateAndSetConfig(data: directData)
                return
            }
            // Key path: an empty/whitespace key fails the gate (ready() throws); a valid key
            // proceeds to the fetch. Validation is bridged through the store because
            // `ConfigValidation` is internal to ConvertSDKCore (invisible to this target).
            if let validationError = await store.validationError(for: configuration) {
                await store.signalError(validationError)
                return
            }
            // Resolve the active provider: the injected one (tests) or a freshly-built real
            // `ConfigFetchService` (production). The fetch service composes the URLSession
            // transport, the coordinated on-disk cache, and a `NoopLogger` (the production
            // default until a real OSLog sink ships; redaction is enforced inside the service).
            let activeProvider: any ConfigProviding = configProvider ?? ConfigFetchService(
                httpClient: URLSessionHTTPClient(sdkVersion: SDKVersion.current),
                fileStore: CoordinatedFileStore(),
                configuration: configuration,
                logger: NoopLogger()
            )
            // Offline-with-cache: a cached config latches ready BEFORE the live fetch, so the SDK
            // is usable immediately when the network is down but a cache exists.
            if let cached = await activeProvider.loadCachedConfig() {
                await store.setConfig(cached)
            }
            // Final fetch, then a GUARDED setConfig. `ConfigStore.setConfig` overwrites the snapshot
            // UNCONDITIONALLY before its ready-latch guard, so calling it with a `nil` live result
            // after a cache hit would DESTROY the good cached snapshot (ready stays latched, but
            // getSnapshot() goes nil — breaking the offline-with-cache contract AC3). The guard runs
            // setConfig only when the live fetch produced a config, OR when there is no snapshot to
            // protect. This yields three behaviors:
            //   * live succeeds        → setConfig(live) refreshes the snapshot (fresh wins).
            //   * live fails, had cache → skipped: the cached snapshot is preserved AND it is a
            //     no-op for the ready signal (already latched by the cache's setConfig above).
            //   * live fails, no cache  → setConfig(nil) runs (snapshot was nil): resolves ready
            //     DEGRADED rather than hanging, the ``ConfigStore`` `nil`-first-load contract.
            // (Option B: the guard lives here so `ConfigStore.setConfig`'s "snapshot = arg" contract
            // stays pure.)
            let live = await activeProvider.fetchLiveConfig()
            // `await` cannot live inside the `||` right operand (it is an autoclosure that does
            // not support concurrency under Swift 6), so the snapshot check is hoisted to its own
            // binding: run setConfig when live produced a config, or when there is no snapshot to
            // protect (the no-cache degraded path).
            let hasSnapshot = await store.getSnapshot() != nil
            if live != nil || !hasSnapshot {
                await store.setConfig(live)
            }
            // Start the foreground / interval refresh scheduler now that the first config has
            // landed and `ready()` will resolve. This runs on EVERY key-path completion (cache-hit
            // OR live-success OR the no-cache degraded path) — the directData path returned far
            // above and never reaches here, so direct-data SDKs correctly get no scheduler (they
            // have no live provider to refresh from). The scheduler reuses the SAME `activeProvider`
            // the load resolved (no second `ConfigFetchService` is built) and the production
            // `NoopLogger` (matching what the fetch service uses). Owned through the `Sendable`
            // `schedulerBox` so this class stays an all-`let` `Sendable final class`.
            let scheduler = ConfigRefreshScheduler(
                configStore: store,
                fetchService: activeProvider,
                logger: NoopLogger(),
                clock: clock,
                refreshIntervalMs: configuration.dataRefreshIntervalMs
            )
            await scheduler.start()
            await schedulerBox.set(scheduler)
        }
    }

    /// Resolves the ONE ``EventSink`` shared by the conversion seam AND the bucketing path.
    ///
    /// When `injected` is non-`nil` (the test seam — a `MockEventSink`) it is used verbatim for BOTH
    /// paths, so the bucketing enqueue becomes observable on the same instance the conversion suite
    /// inspects. When `injected` is `nil` (production) the real ``EventQueue`` (Epic 5 / Story 1) is
    /// built and returned: it batches by ``ConvertConfiguration/eventsBatchSize`` and the
    /// ``ConvertConfiguration/eventsReleaseIntervalMs`` interval, ships through a
    /// ``URLSessionEventUploader`` over a ``URLSessionHTTPClient`` (which applies the non-overridable
    /// `ConvertAgent/<version>` User-Agent), fires ``SystemEvent/apiQueueReleased`` on the SHARED
    /// `eventBus`, and honours the static ``ConvertConfiguration/networkTracking`` gate.
    ///
    /// The `accountId`/`projectId` stamped on the envelope are `""` here: they live on the config
    /// SNAPSHOT (loaded asynchronously after init), not on ``ConvertConfiguration``, so at construction
    /// they default to empty — the same pre-config default ``ConvertContext`` applies to the sticky
    /// store key. Threading the resolved snapshot's account/project into the queue is a later-story
    /// concern; Story 5.1 delivers the foreground queue with the empty pre-config attribution.
    ///
    /// A `static` helper (not an instance method) so it can run BEFORE every stored property of `self`
    /// is initialized — the `init` calls it to build a LOCAL that flows into both `self.eventSink` and
    /// ``ExperienceManager/makeDefault(decisionStore:eventBus:logger:eventSink:)``. The production
    /// ``EventQueue`` uses ``SystemClock`` (the wall clock); the injectable `clock` on `init` drives
    /// the config refresh scheduler, not this queue (the queue's determinism is exercised at the
    /// `EventQueue` unit level with a stepping clock, not through the SDK composition root).
    ///
    /// - Parameters:
    ///   - injected: An explicit sink (tests pass a `MockEventSink`), or `nil` for the production queue.
    ///   - configuration: The SDK configuration carrying the batch size, release interval, track
    ///     endpoint, SDK key, and the `network.tracking` gate.
    ///   - eventBus: The SDK's shared bus the queue fires ``SystemEvent/apiQueueReleased`` on.
    ///   - store: The durable ``EventQueueStore`` built in `init` over the SDK's real logger and
    ///     injected into the production ``EventQueue``; unused on the injected-mock path (it returns
    ///     first).
    /// - Returns: The injected sink, or a freshly-built real ``EventQueue``.
    private static func resolveEventSink(
        injected: (any EventSink)?,
        configuration: ConvertConfiguration,
        eventBus: EventBus,
        store: any EventQueueStore
    ) -> any EventSink {
        if let injected {
            return injected
        }
        let uploader = URLSessionEventUploader(
            httpClient: URLSessionHTTPClient(sdkVersion: SDKVersion.current),
            trackEndpoint: configuration.apiTrackEndpoint,
            sdkKey: configuration.sdkKey
        )
        // The durable pending-event-queue store (Story 5.2) is BUILT in `init` (over the SDK's real
        // logger) and threaded in here, so `EventQueue`'s non-defaulted `store:` is always injected —
        // the on-disk fallback, disk-first drain merge, and cold-start recovery are never silently
        // skipped. The injected-mock branch above returned before this, so `store` is only consumed
        // on the production path.
        return EventQueue(
            accountId: "",
            projectId: "",
            batchSize: configuration.eventsBatchSize,
            releaseIntervalMs: configuration.eventsReleaseIntervalMs,
            uploader: uploader,
            eventBus: eventBus,
            trackingEnabled: configuration.networkTracking,
            store: store
        )
    }

    /// Cancels the refresh scheduler when this handle is released.
    ///
    /// The scheduler owns long-lived `Task`s (its interval loop + two notification observers) that
    /// must be stopped when the SDK handle deallocates. `deinit` cannot `await`, so it hands off to a
    /// detached `Task` that cancels through the (`Sendable`) ``schedulerBox``. Capturing the box into
    /// a LOCAL first (`let box = schedulerBox`) and referencing only that local inside the `Task`
    /// keeps the closure off `self` — so this deinit captures nothing but a `Sendable` actor and is
    /// data-race-safe. A no-op when no scheduler was set (e.g. the directData path, or a handle
    /// released before the load `Task` finished): ``SchedulerBox/cancelAndClear()`` optional-chains.
    deinit {
        let box = schedulerBox
        Task { await box.cancelAndClear() }
    }

    /// Creates the SDK from a configuration, using the real config fetch. Non-throwing and
    /// non-blocking; validation and the live fetch surface through `ready()`. Passing no
    /// `configProvider` to the internal init makes it build the real ``ConfigFetchService``
    /// (cache-load → live-fetch), so this path reads the on-disk cache then refreshes over the
    /// network, resolving `ready()` degraded only when both are unavailable.
    /// - Parameter configuration: The SDK configuration.
    public convenience init(configuration: ConvertConfiguration) {
        // Pass `configProvider: nil` explicitly: it disambiguates this call to the internal
        // designated initializer (whose other parameters default) rather than re-entering this
        // same convenience initializer — and `nil` selects the production real `ConfigFetchService`.
        self.init(configuration: configuration, configProvider: nil)
    }

    /// Creates the SDK from a pre-fetched config payload (the direct-data path). Non-throwing
    /// and non-blocking: empty/invalid `configData` makes `ready()` throw
    /// ``ConvertError/invalidConfiguration(_:)``; the SDK key is not used on this path, so a
    /// placeholder configuration is synthesized and validation routes to the data. The
    /// direct-data path bypasses the config provider entirely (it validates `directData`), so no
    /// provider is supplied.
    /// - Parameter configData: The pre-fetched project config bytes.
    public convenience init(configData: Data) {
        // The key is irrelevant on the direct-data path (the load task validates `directData`,
        // not the key), so a placeholder key carries the configuration. A blank key here would
        // be wrong — it is never validated on this path; using a sentinel keeps that explicit.
        let placeholder = ConvertConfiguration(sdkKey: "direct-data")
        self.init(configuration: placeholder, directData: configData)
    }

    /// Suspends until config is available. Resolves on a successful (or degraded) load; throws
    /// ``ConvertError`` only on an unrecoverable configuration error (empty SDK key, or
    /// empty/invalid direct-data). A transient network failure does NOT throw — the SDK
    /// resolves degraded. Latches: once resolved, subsequent calls return immediately.
    public func ready() async throws {
        try await configStore.waitForReady()
    }

    /// Subscribes `callback` to `event` on the SDK's event bus. Returns a token to pass to
    /// ``off(_:)`` to cancel. Forwards directly to the shared ``EventBus``.
    public func on(
        _ event: SystemEvent,
        callback: @escaping @Sendable (EventPayloadValue) -> Void
    ) async -> EventListenerToken {
        await eventBus.on(event, callback: callback)
    }

    /// Cancels the subscription identified by `token`. Idempotent. Forwards to the shared
    /// ``EventBus``.
    public func off(_ token: EventListenerToken) async {
        await eventBus.off(token)
    }

    /// Creates a ``ConvertContext`` bound to this SDK. Synchronous and non-blocking: a context
    /// can be created before `ready()` resolves (it does not wait on config load).
    ///
    /// The effective visitor ID is resolved NOW through ``VisitorContextManager``: an explicit
    /// `visitorId` is returned verbatim (no store access); otherwise the injected
    /// Keychain/mirror stores are read, and on a miss a fresh `UUID().uuidString` is generated and
    /// persisted. The `attributes` are coerced into the closed ``ConvertValue`` set HERE in
    /// `createContext` (unsupported values dropped and logged at DEBUG) before the context is
    /// constructed. Every context receives this SDK's ONE canonical ``DecisionStore``.
    /// The downstream bucketing/segmentation engines that CONSUME this identity arrive in Epics 3–4.
    /// - Parameters:
    ///   - visitorId: Optional caller-supplied visitor identifier; when non-empty it is used verbatim.
    ///   - attributes: Optional visitor attributes for segmentation; non-scalar values are dropped.
    public func createContext(visitorId: String? = nil, attributes: [String: Any]? = nil) -> ConvertContext {
        // The SDK's injected `logger` (default ``NoopLogger`` — the production logging path until a real
        // OSLog sink ships; the conversion-tracking suite injects a `MockLogger`). Shared by the
        // visitor-ID resolver, the attribute coercion below, AND handed to the `ConvertContext` so its
        // `trackConversion` drop-path WARNs surface on the same sink.
        let logger = self.logger
        // Resolve via the pure-logic manager: explicit ID verbatim, else persisted store value, else a
        // freshly generated + persisted UUID.
        let resolvedId = VisitorContextManager.resolveVisitorId(
            provided: visitorId,
            secureStore: secureStore,
            keyValueStore: keyValueStore,
            logger: logger
        )
        // Coerce the loosely-typed attributes into the closed `ConvertValue` set HERE (where the logger
        // is in scope) rather than inside `ConvertContext`, so a dropped key can be logged at DEBUG —
        // matching the SDK's "log, never crash" pattern. Per key, any value that is not one of the four
        // supported scalars (nested dict/array/object/NSNull) is dropped — it is not a segment-matchable
        // scalar — while supported siblings in the same map survive (per-key filter, never whole-map
        // rejection). The public parameter stays `[String: Any]?` and `ConvertContext.attributes` stays
        // `[String: Any]`, so the consumer surface is unchanged.
        var coercedAttributes: [String: ConvertValue] = [:]
        for (key, value) in attributes ?? [:] {
            if let convertValue = ConvertValue(any: value) {
                coercedAttributes[key] = convertValue
            } else {
                logger.log(
                    level: .debug,
                    type: "ConvertContext",
                    method: "createContext",
                    message: "attribute '\(key)' has unsupported type — dropped"
                )
            }
        }
        return ConvertContext(
            sdk: self,
            visitorId: resolvedId,
            attributes: coercedAttributes,
            decisionStore: decisionStore,
            experienceManager: experienceManager,
            featureManager: featureManager,
            eventSink: eventSink,
            eventBus: eventBus,
            logger: logger
        )
    }
}
