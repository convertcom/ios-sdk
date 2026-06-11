// Tests/ConvertSDKCoreTests/Config/ConfigTests.swift
// `@testable` import: `ConfigValidation` is `internal` by design (SDK-internal config
// validation, not public API). Mirrors the established convention in this target for
// reaching internal symbols (see EventBusTests / ConfigDecodeTests). `ConvertConfiguration`
// and `CacheLevel` are `public`, but a single `@testable` import covers all three.
import Foundation
import Testing
@testable import ConvertSDKCore

/// RED-phase contract for the SDK initializer configuration surface (Epic 2 / Story 2).
///
/// CONTRACT under test (the GREEN-phase implementer MUST satisfy these):
/// - `ConvertConfiguration(sdkKey:)` defaults every non-`sdkKey` field to the exact value
///   in the spec table — endpoints carry NO trailing slash, numeric knobs alias `Defaults`,
///   and the optionals (`sdkKeySecret`, `environment`) default to `nil`.
/// - `CacheLevel` is a `String`-backed, `CaseIterable` enum whose cases are exactly
///   `[.normal, .low]` with raw values `"normal"` / `"low"`.
/// - `ConfigValidation.validate(_:)` rejects a blank/whitespace `sdkKey` and the empty
///   `Data` payload with `ConvertError.invalidConfiguration`, and accepts any non-empty
///   counterpart silently.
///
/// None of `ConvertConfiguration` / `CacheLevel` / `ConfigValidation` exist yet, so this
/// suite is EXPECTED to fail to compile (RED). That is the correct outcome of this phase.
@Suite("ConvertConfiguration & CacheLevel")
struct ConfigTests {
    // MARK: Shared fixtures (SonarQube 3% new-duplicated-lines gate)

    /// One factory for the system-under-test instead of re-spelling the initializer per
    /// test. Defaulting `sdkKey` keeps the default-asserting test argument-free while the
    /// validation tests pass the key they need to exercise.
    private static func makeConfig(sdkKey: String = "test") -> ConvertConfiguration {
        ConvertConfiguration(sdkKey: sdkKey)
    }

    /// The canonical CDN endpoint shared by both `apiConfigEndpoint` and `apiTrackEndpoint`.
    /// Asserting against this single literal (NO trailing slash) keeps the expected value in
    /// one place for both endpoint checks.
    private static let canonicalEndpoint = "https://cdn-4.convertexperiments.com/api/v1"

    // MARK: ConvertConfiguration defaults

    @Test("ConvertConfiguration(sdkKey:) populates every default from the spec table")
    func defaultsMatchSpec() {
        let config = Self.makeConfig()

        // Endpoints — canonical CDN base, NO trailing slash.
        #expect(config.apiConfigEndpoint == Self.canonicalEndpoint)
        #expect(config.apiTrackEndpoint == Self.canonicalEndpoint)

        // Optionals default to nil.
        #expect(config.sdkKeySecret == nil)
        #expect(config.environment == nil)

        // Bucketing knobs alias the JS-parity `Defaults` constants (no re-spelled literals).
        #expect(config.bucketingMaxTraffic == Defaults.maxTraffic)
        #expect(config.bucketingHashSeed == Defaults.hashSeed)

        // Timing / batching knobs alias `Defaults`.
        #expect(config.dataRefreshIntervalMs == Defaults.dataRefreshIntervalMs)
        #expect(config.eventsBatchSize == Defaults.batchSize)
        #expect(config.eventsReleaseIntervalMs == Defaults.releaseIntervalMs)

        // Rule-matching toggles.
        #expect(config.ruleKeysCaseSensitive == true)
        #expect(config.ruleNegation == false)

        // Observability + networking defaults.
        #expect(config.logLevel == .warn)
        #expect(config.networkTracking == true)
        #expect(config.networkCacheLevel == .normal)
    }

    // MARK: CacheLevel shape

    @Test("CacheLevel enumerates exactly [.normal, .low] with matching raw values")
    func cacheLevelCases() {
        #expect(CacheLevel.allCases == [.normal, .low])
        #expect(CacheLevel.normal.rawValue == "normal")
        #expect(CacheLevel.low.rawValue == "low")
    }

    // MARK: ConfigValidation — sdkKey

    @Test("validate(_:) rejects a blank or whitespace-only sdkKey", arguments: ["", "   ", "\n\t"])
    func validateThrowsOnEmptyOrWhitespaceKey(_ blankKey: String) {
        #expect(throws: ConvertError.self) {
            try ConfigValidation.validate(Self.makeConfig(sdkKey: blankKey))
        }
    }

    @Test("validate(_:) accepts a non-empty sdkKey")
    func validateAcceptsNonEmptyKey() {
        #expect(throws: Never.self) {
            try ConfigValidation.validate(Self.makeConfig(sdkKey: "sk_live_x"))
        }
    }

    // MARK: ConfigValidation — Data payload (stub; real decode is a later story)

    @Test("validate(_:) rejects empty config Data but accepts a non-empty payload")
    func validateDataThrowsOnEmpty() {
        #expect(throws: ConvertError.self) {
            try ConfigValidation.validate(Data())
        }
        // `{}` — a minimal non-empty payload the stub must accept without decoding it.
        #expect(throws: Never.self) {
            try ConfigValidation.validate(Data([0x7b, 0x7d]))
        }
    }
}
