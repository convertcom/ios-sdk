// ConvertConfiguration.swift
// The public SDK initializer configuration value (Epic 2 / Story 2).
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Immutable configuration passed to the SDK initializer.
///
/// ```swift
/// let config = ConvertConfiguration(sdkKey: "your-sdk-key")
/// let custom = ConvertConfiguration(sdkKey: "your-sdk-key", logLevel: .debug)
/// ```
///
/// Every field except ``sdkKey`` carries a JS-SDK-parity default (see ``Defaults`` for the
/// numeric knobs). All stored properties are `let`, so the struct is a `Sendable` value:
/// once constructed it never mutates. It is deliberately NOT `Codable` — it is an input
/// configuration, not a wire payload.
public struct ConvertConfiguration: Sendable {
    /// The canonical Convert CDN config/track base — JS-canonical, NO trailing slash
    /// (References F-029). Defined once and shared by both endpoint defaults so the literal
    /// never drifts between the two parameters (overloaded-literal hazard). Story 2.3 route
    /// paths carry the leading "/", so this base must not end in one.
    ///
    /// `public` (matching the ``Defaults`` precedent) because it is referenced from the
    /// default-argument expressions of the `public` initializer, and a public default-arg
    /// value may only reference symbols visible at the (cross-module) call site.
    public static let defaultAPIBase = "https://cdn-4.convertexperiments.com/api/v1"

    /// The project SDK key identifying the Convert project to load.
    public let sdkKey: String
    /// Optional SDK key secret for authenticated endpoints; `nil` when unused.
    public let sdkKeySecret: String?
    /// Optional environment selector (e.g. a named environment); `nil` selects the default.
    public let environment: String?
    /// Base URL for fetching project configuration. JS-canonical base, no trailing slash.
    public let apiConfigEndpoint: String
    /// Base URL for delivering tracking events. JS-canonical base, no trailing slash.
    public let apiTrackEndpoint: String
    /// Inclusive upper bound of the bucketing traffic range (`0..<bucketingMaxTraffic`).
    public let bucketingMaxTraffic: Int
    /// MurmurHash3 seed used when hashing the bucketing key.
    public let bucketingHashSeed: UInt32
    /// Interval, in milliseconds, between remote configuration refreshes.
    public let dataRefreshIntervalMs: Int
    /// Number of queued events flushed per release batch.
    public let eventsBatchSize: Int
    /// Interval, in milliseconds, between event-queue release attempts.
    public let eventsReleaseIntervalMs: Int
    /// Whether rule key comparisons are case-sensitive.
    public let ruleKeysCaseSensitive: Bool
    /// Whether rule matching applies negation semantics.
    public let ruleNegation: Bool
    /// Log severity threshold; messages below this level are suppressed.
    public let logLevel: LogLevel
    /// Whether event/network tracking is enabled.
    public let networkTracking: Bool
    /// CDN cache level applied to config fetches.
    public let networkCacheLevel: CacheLevel

    /// Creates a configuration, defaulting every field except ``sdkKey`` to its JS-parity value.
    /// - Parameters:
    ///   - sdkKey: The project SDK key identifying the Convert project.
    ///   - sdkKeySecret: Optional SDK key secret; defaults to `nil`.
    ///   - environment: Optional environment selector; defaults to `nil`.
    ///   - apiConfigEndpoint: Config fetch base URL. JS-canonical base, no trailing slash
    ///     (References F-029); Story 2.3 route paths carry the leading "/".
    ///   - apiTrackEndpoint: Event delivery base URL. JS-canonical base, no trailing slash
    ///     (References F-029); Story 2.3 route paths carry the leading "/".
    ///   - bucketingMaxTraffic: Inclusive upper bound of the bucket range.
    ///   - bucketingHashSeed: MurmurHash3 seed for the bucketing key.
    ///   - dataRefreshIntervalMs: Interval between remote configuration refreshes.
    ///   - eventsBatchSize: Events flushed per release batch.
    ///   - eventsReleaseIntervalMs: Interval between event-queue release attempts.
    ///   - ruleKeysCaseSensitive: Whether rule key comparisons are case-sensitive.
    ///   - ruleNegation: Whether rule matching applies negation semantics.
    ///   - logLevel: Log severity threshold.
    ///   - networkTracking: Whether event/network tracking is enabled.
    ///   - networkCacheLevel: CDN cache level for config fetches.
    public init(
        sdkKey: String,
        sdkKeySecret: String? = nil,
        environment: String? = nil,
        apiConfigEndpoint: String = ConvertConfiguration.defaultAPIBase,
        apiTrackEndpoint: String = ConvertConfiguration.defaultAPIBase,
        bucketingMaxTraffic: Int = Defaults.maxTraffic,
        bucketingHashSeed: UInt32 = Defaults.hashSeed,
        dataRefreshIntervalMs: Int = Defaults.dataRefreshIntervalMs,
        eventsBatchSize: Int = Defaults.batchSize,
        eventsReleaseIntervalMs: Int = Defaults.releaseIntervalMs,
        ruleKeysCaseSensitive: Bool = true,
        ruleNegation: Bool = false,
        logLevel: LogLevel = .warn,
        networkTracking: Bool = true,
        networkCacheLevel: CacheLevel = .normal
    ) {
        self.sdkKey = sdkKey
        self.sdkKeySecret = sdkKeySecret
        self.environment = environment
        self.apiConfigEndpoint = apiConfigEndpoint
        self.apiTrackEndpoint = apiTrackEndpoint
        self.bucketingMaxTraffic = bucketingMaxTraffic
        self.bucketingHashSeed = bucketingHashSeed
        self.dataRefreshIntervalMs = dataRefreshIntervalMs
        self.eventsBatchSize = eventsBatchSize
        self.eventsReleaseIntervalMs = eventsReleaseIntervalMs
        self.ruleKeysCaseSensitive = ruleKeysCaseSensitive
        self.ruleNegation = ruleNegation
        self.logLevel = logLevel
        self.networkTracking = networkTracking
        self.networkCacheLevel = networkCacheLevel
    }
}
