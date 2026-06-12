// ConvertSDK.swift
// Public entry point for the Convert iOS SDK (Epic 2 / Story 2).
// Re-exports ConvertSDKCore so consumers need only `import ConvertSDK`.

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
    internal init(
        configuration: ConvertConfiguration,
        configProvider: (any ConfigProviding)? = nil,
        eventBus: EventBus = EventBus(),
        directData: Data? = nil,
        clock: any Clock = SystemClock()
    ) {
        self.configuration = configuration
        self.eventBus = eventBus
        self.directData = directData
        let store = ConfigStore(eventBus: eventBus)
        self.configStore = store

        // Capture the injected provider (if any) for the detached load task. When `nil`, the
        // real `ConfigFetchService` is built inside the task (off the construction path, so init
        // stays non-blocking).
        let provider = configProvider
        // Capture the box and the clock as locals so the detached `Task` closure picks up THESE
        // (not `self`) — keeping the closure off `self` for everything but the already-captured
        // `store`. `schedulerBox` is a `Sendable` actor and `clock` is `Sendable`, so both cross
        // into the `Task` with no data-race warning. The scheduler is built INSIDE the Task (after
        // the first config lands), so `clock` need not be a stored property — this local is its
        // only reach.
        let schedulerBox = self.schedulerBox
        let clock = clock
        Task {
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
            let activeProvider: any ConfigProviding = provider ?? ConfigFetchService(
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
    /// can be created before `ready()` resolves (it does not wait on config load). The
    /// `visitorId` and `attributes` are accepted now and wired into bucketing/segmentation in
    /// Epics 3–4.
    /// - Parameters:
    ///   - visitorId: Optional caller-supplied visitor identifier.
    ///   - attributes: Optional visitor attributes for segmentation.
    public func createContext(visitorId: String? = nil, attributes: [String: Any]? = nil) -> ConvertContext {
        ConvertContext(sdk: self)
    }
}
