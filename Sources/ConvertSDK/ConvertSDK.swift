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
    let configuration: ConvertConfiguration
    /// The bus on which `.ready` (and later system events) fire; shared with ``configStore``.
    let eventBus: EventBus
    /// Owns the "config present" state and the one-shot ready gate.
    let configStore: ConfigStore
    /// Loads the project configuration. A no-op ``StubConfigLoader`` for the public key
    /// initializer until Story 2.3; a mock in tests.
    let configLoader: ConfigLoader
    /// Pre-fetched config payload for the direct-data initializer; `nil` on the key path.
    let directData: Data?

    /// Developer-assigned convenience, nil until set; not a singleton and not installed by
    /// init. `nonisolated(unsafe)` because it is intended to be assigned once at app startup,
    /// not mutated concurrently (Story 2.2 Dev Notes Option A).
    nonisolated(unsafe) public static var shared: ConvertSDK?

    /// Dependency-injecting initializer (the test seam). Stores its dependencies, creates the
    /// ``ConfigStore`` over the shared ``EventBus``, then launches the detached config-load
    /// task. Non-throwing and non-blocking — validation and loading happen in the task, and
    /// surface through `ready()`.
    /// - Parameters:
    ///   - configuration: The SDK configuration (its `sdkKey` is validated by the load task).
    ///   - configLoader: The loader used to fetch config (a no-op stub in production until
    ///     Story 2.3; a mock in tests).
    ///   - eventBus: The bus shared with the ``ConfigStore``; defaults to a fresh bus.
    ///   - directData: A pre-fetched config payload for the direct-data path; `nil` (the
    ///     default) selects the key path. When present, the load task validates the data
    ///     instead of the key.
    internal init(
        configuration: ConvertConfiguration,
        configLoader: ConfigLoader,
        eventBus: EventBus = EventBus(),
        directData: Data? = nil
    ) {
        self.configuration = configuration
        self.configLoader = configLoader
        self.eventBus = eventBus
        self.directData = directData
        let store = ConfigStore(eventBus: eventBus)
        self.configStore = store

        let sdkKey = configuration.sdkKey
        Task {
            if let directData {
                // Direct-data path: validate the payload (empty/invalid → ready() throws).
                await store.validateAndSetConfig(data: directData)
                return
            }
            // Key path: an empty/whitespace key fails the gate (ready() throws); a valid key
            // proceeds to the load attempt. Validation is bridged through the store because
            // `ConfigValidation` is internal to ConvertSDKCore (invisible to this target).
            if let validationError = await store.validationError(for: configuration) {
                await store.signalError(validationError)
                return
            }
            do {
                try await configLoader.load(sdkKey: sdkKey)
            } catch {
                // Transient network/transport failure → resolve ready() DEGRADED: fall through
                // to setConfig so the SDK is usable; never rethrow a transient load error.
            }
            await store.setConfig()
        }
    }

    /// Creates the SDK from a configuration, using the production loader. Non-throwing and
    /// non-blocking; validation/loading surface through `ready()`. Story 2.3 swaps the no-op
    /// ``StubConfigLoader`` for the real `URLSession`-backed adapter.
    /// - Parameter configuration: The SDK configuration.
    public convenience init(configuration: ConvertConfiguration) {
        self.init(configuration: configuration, configLoader: StubConfigLoader())
    }

    /// Creates the SDK from a pre-fetched config payload (the direct-data path). Non-throwing
    /// and non-blocking: empty/invalid `configData` makes `ready()` throw
    /// ``ConvertError/invalidConfiguration(_:)``; the SDK key is not used on this path, so a
    /// placeholder configuration is synthesized and validation routes to the data.
    /// - Parameter configData: The pre-fetched project config bytes.
    public convenience init(configData: Data) {
        // The key is irrelevant on the direct-data path (the load task validates `directData`,
        // not the key), so a placeholder key carries the configuration. A blank key here would
        // be wrong — it is never validated on this path; using a sentinel keeps that explicit.
        let placeholder = ConvertConfiguration(sdkKey: "direct-data")
        self.init(configuration: placeholder, configLoader: StubConfigLoader(), directData: configData)
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
