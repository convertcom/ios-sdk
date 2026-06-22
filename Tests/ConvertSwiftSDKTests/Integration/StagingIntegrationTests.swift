// Tests/ConvertSwiftSDKTests/Integration/StagingIntegrationTests.swift
//
// FR69 staging integration suite (Epic 5 / Story 5). Two modes against the REAL FS-Test-Proj staging
// config (account 10035569 / project 10034190 — the AC5 staging coordinates):
//
//   • STATIC mode (always-runs CI test, OFFLINE): loads the committed `staging-config-snapshot.json`
//     — a REAL captured staging CDN config, byte-identical to the core target's `cdn-config-baseline`
//     — through the PUBLIC FR7 direct-data path (`ConvertSwiftSDK(configData:)`), with NO network at all.
//
//   • LIVE mode (network, env-gated SKIP): builds a real-CDN `ConvertConfiguration` and exercises the
//     real config GET against `cdn-4.convertexperiments.com`. SKIPPED (not failed) unless
//     `CONVERT_STAGING_SDK_KEY` is set, so it is inert in ordinary CI / local runs where no secret
//     exists, and runs only in the manual/release CI gate that injects the key.
//
// This file touches NO Sources/ production code. The only non-test additions are the committed real
// staging fixture and a Package.swift `.copy("Fixtures")` resource declaration (build-config/test-data).
//
// ── Why the STATIC assertion on the RAW staging snapshot is `variation == nil` (EVIDENCED) ──────────
// `ConvertSwiftSDK(configData:)` now DECODES the bytes into a `ProjectConfig`
// (`ConfigStore.validateAndSetConfig`), so `getSnapshot()` is non-nil after `ready()` and the four real
// experiences are retained (the generated `ExperienceTypes` enum carries `"a/b_fullstack"` since the
// serving-spec regen). Yet `runExperience("test-experience-ab-fullstack-4")` still returns `nil` on the
// RAW snapshot for ONE remaining reason: that experience is LOCATION-GATED (`locations: ["1003352"]`,
// the "pricing-location" whose rule needs a `location == "pricing"` property), and
// `ConvertContext.runExperience` passes an EMPTY `locationProperties` map on native (native location
// targeting is out of scope — see the `runExperience` doc). The location gate therefore fails and the
// variation degrades to `nil` — crash-safe (AC9), never a throw. All four real staging experiences are
// location-gated, so the raw snapshot buckets none of them offline.
//
// The companion test `directDataUngatedExperienceBuckets()` proves the OTHER side: the SAME staging
// bytes with each experience's audience + location gates cleared DO bucket a non-nil Variation through
// the public configData path — i.e. the decode + bucketing pipeline is whole, and the only thing the
// raw snapshot lacks is satisfied location properties. That is exactly what the demo app's bundled
// `demo-config.json` does (real staging config, gates cleared) so its "Run Experience" buckets.
//
// So this suite asserts: the SDK READIES on real staging bytes (FR7 ingestion works end-to-end); the
// committed fixture is the GENUINE staging config (its `ProjectConfig` decode recovers the AC5
// account/project coordinates and all four named experiences, not a stub); `runExperience` on the
// location-gated raw key is crash-safe (`== nil`, never a throw); AND an ungated experience buckets.
//
// ── No wall-clock waits (NFR21/NFR22) ─────────────────────────────────────────────────────────────
// Static mode awaits `ready()` and each `runExperience` — all happens-before, no sleep/poll. Live mode
// (when it runs) likewise only `await`s `ready()` and `runExperience`.
//
// ── SonarQube 3% new-duplicated-lines gate ────────────────────────────────────────────────────────
// The snapshot bytes load through the single `Self.loadStagingData()` helper; the real experience key
// is the single `Self.stagingExperienceKey` constant; the AC5 coordinates are the single
// `Self.stagingAccountId` / `Self.stagingProjectId` constants. No case re-inlines the load or the ids.
//
// ── Isolation (bd-ilx) ────────────────────────────────────────────────────────────────────────────
// The PUBLIC `ConvertSwiftSDK(configData:)` init has no `DecisionStore` injection seam (that is the internal
// init only), so the SDK uses its shared production `DecisionStore`. Each test uses a UNIQUE per-run
// `visitorId` (`"staging-static-<UUID>"`), so sticky store keys never collide across runs — sufficient
// isolation here without a store injection.
import Testing
import Foundation
@testable import ConvertSwiftSDK

@Suite("StagingIntegration")
struct StagingIntegrationTests {

    // MARK: - Fixed staging identifiers (single owner each — SonarQube 3% gate)

    /// The committed real staging snapshot resource (no extension); lives under the target's `Fixtures`
    /// subdirectory, bundled verbatim by the Package.swift `.copy("Fixtures")` declaration.
    private static let snapshotResource = "staging-config-snapshot"

    /// A real experience `key` present in the staging config (`type: "a/b_fullstack"`, audiences `[]`,
    /// locations `["1003352"]`). Driven through `runExperience` to prove the public call is crash-safe
    /// on real staging data.
    private static let stagingExperienceKey = "test-experience-ab-fullstack-4"

    /// The AC5 staging account id (`account_id`) the committed snapshot carries — proves the fixture is
    /// the genuine FS-Test-Proj staging capture, not a stub.
    private static let stagingAccountId = "10035569"

    /// The AC5 staging project id (`project.id`) the committed snapshot carries.
    private static let stagingProjectId = "10034190"

    /// The number of experiences the real staging config carries (matches the core target's
    /// `ProjectConfigTests` headline assertion on the same bytes).
    private static let stagingExperienceCount = 4

    // MARK: - Snapshot load (single owner — SonarQube 3% gate)

    /// Loads the committed real staging snapshot bytes from the test bundle. `.copy("Fixtures")` bundles
    /// the directory verbatim, so the resource resolves under the `Fixtures` subdirectory (the same
    /// `Bundle.module.url(...subdirectory: "Fixtures")` path `ConfigDecodeTests` / `ProjectConfigTests`
    /// use in the core target). `#require` reports a clean failure rather than force-unwrapping (no `!`
    /// — swiftlint `force_unwrapping`).
    private static func loadStagingData() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: snapshotResource, withExtension: "json", subdirectory: "Fixtures"),
            "the committed staging snapshot must be bundled as a resource"
        )
        return try Data(contentsOf: url)
    }

    // MARK: - FR69 static mode (offline — always runs)

    /// Drives the PUBLIC FR7 direct-data path on the REAL committed staging snapshot, entirely offline:
    /// `ConvertSwiftSDK(configData:)` → `ready()` → `createContext` → `runExperience`. Asserts the SDK
    /// READIES on the genuine staging bytes (no throw) and that `runExperience` on a real staging key is
    /// crash-safe (degrades to `nil` on the not-yet-decoded direct-data snapshot — AC9; see the file
    /// header for why a non-nil `Variation` is unobtainable here, with evidence). No network, no stub —
    /// the direct-data path bypasses transport entirely, so `URLProtocolStub` is intentionally NOT used.
    @Test("static mode: the SDK readies on the real staging snapshot and runExperience is crash-safe")
    func stagingStaticMode() async throws {
        let data = try Self.loadStagingData()

        // PUBLIC FR7 direct-data init — readies on the real staging bytes WITHOUT throwing (the
        // ingestion path accepts genuine staging data). A throw here would fail the test.
        let sdk = ConvertSwiftSDK(configData: data)
        try await sdk.ready()

        // UNIQUE visitorId (bd-ilx isolation) — sticky keys never collide across runs.
        let context = sdk.createContext(visitorId: "staging-static-\(UUID().uuidString)")

        // The public call is crash-safe on real staging data. The config IS decoded now, but this key
        // (`test-experience-ab-fullstack-4`) is LOCATION-GATED and native passes empty location
        // properties, so the location gate fails and the variation degrades to `nil` (file header) —
        // NOT a thrown error. `directDataUngatedExperienceBuckets` below covers the non-nil side.
        let variation = await context.runExperience(Self.stagingExperienceKey)
        // Crash-safe: the location-gated key degrades to nil on the decoded snapshot, not by throwing.
        #expect(variation == nil, "location-gated staging key degrades to nil, never throws")

        // Independently prove the committed fixture is the GENUINE staging config (not a stub): decoding
        // its `ProjectConfig` recovers the AC5 account/project coordinates and all four named staging
        // experiences — mirroring the core target's `ProjectConfigTests` assertions on the same bytes.
        let config = try JSONDecoder().decode(ProjectConfig.self, from: data)
        #expect(config.accountId == Self.stagingAccountId, "the snapshot carries the AC5 staging account_id")
        #expect(config.project?.id == Self.stagingProjectId, "the snapshot carries the AC5 staging project.id")
        let experiences = try #require(config.experiences, "the staging config decodes its experiences")
        #expect(
            experiences.count == Self.stagingExperienceCount,
            "all four real staging experiences are retained in the decoded config"
        )
    }

    // MARK: - FR7 direct-data: an UNGATED experience buckets (decode + bucketing pipeline whole)

    /// The committed staging snapshot with every experience's `audiences` and `locations` cleared to
    /// `[]` — the in-test twin of the demo app's `demo-config.json` transform — so an experience buckets
    /// without native audience/location context. Decodes the snapshot to a mutable JSON object, clears
    /// the two gate arrays on each experience, and re-encodes. `#require`s rather than force-unwraps
    /// (swiftlint `force_unwrapping`).
    private static func ungatedStagingData() throws -> Data {
        let object = try JSONSerialization.jsonObject(with: try loadStagingData())
        var root = try #require(object as? [String: Any], "the staging snapshot must decode to a JSON object")
        let experiences = try #require(
            root["experiences"] as? [[String: Any]],
            "the staging snapshot must carry an experiences array"
        )
        root["experiences"] = experiences.map { experience in
            var ungated = experience
            ungated["audiences"] = []
            ungated["locations"] = []
            return ungated
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Proves the OTHER side of the static contract: the SAME staging bytes with each experience's
    /// audience + location gates cleared bucket a NON-nil `Variation` through the PUBLIC configData path
    /// (`ConvertSwiftSDK(configData:)` → `ready()` → `runExperience`). Together with `stagingStaticMode`
    /// (location-gated key → nil) this shows the decode + bucketing pipeline is whole and the raw
    /// snapshot only lacks satisfied location properties — exactly what the demo app's bundled
    /// `demo-config.json` relies on. A UNIQUE `visitorId` keeps sticky keys from colliding across runs.
    @Test("direct-data: an ungated experience buckets a non-nil variation via configData")
    func directDataUngatedExperienceBuckets() async throws {
        let sdk = ConvertSwiftSDK(configData: try Self.ungatedStagingData())
        try await sdk.ready()

        let context = sdk.createContext(visitorId: "staging-ungated-\(UUID().uuidString)")
        let variation = await context.runExperience(Self.stagingExperienceKey)

        let resolved = try #require(
            variation,
            "an ungated experience must bucket a variation through the direct-data configData path"
        )
        #expect(
            resolved.experienceKey == Self.stagingExperienceKey,
            "the bucketed variation carries its source experience key"
        )
    }

    /// Proves the run-time location activation: the RAW staging snapshot keeps `test-experience-ab-fullstack-4`
    /// LOCATION-GATED (location `1003352` "pricing-location", rule `location == "pricing"`). Supplying that
    /// property at `createContext(locationProperties:)` satisfies the gate, so the experience buckets a non-nil
    /// `Variation` — without de-gating the config. Parity with Android `setLocationProperties` / JS+PHP
    /// `locationProperties`. The mirror case (no property → nil) is `stagingStaticMode`.
    @Test("direct-data: a supplied location property activates a location-gated experience")
    func locationPropertyActivatesGatedExperience() async throws {
        let sdk = ConvertSwiftSDK(configData: try Self.loadStagingData())
        try await sdk.ready()

        let context = sdk.createContext(
            visitorId: "staging-loc-\(UUID().uuidString)",
            locationProperties: ["location": "pricing"]
        )
        let variation = await context.runExperience(Self.stagingExperienceKey)

        let resolved = try #require(
            variation,
            "the matching location property must satisfy the location gate and bucket the experience"
        )
        #expect(resolved.experienceKey == Self.stagingExperienceKey, "the bucketed variation carries its key")
    }

    // MARK: - FR69 live mode (network — env-gated SKIP)

    // Live staging integration over the real CDN. SKIPPED (not failed) unless `CONVERT_STAGING_SDK_KEY`
    // is present: the `.enabled(if:)` trait marks the test as skipped when the env var is absent, which
    // it WILL be in ordinary CI / local runs (no secret exists), so the test is inert there rather than
    // failing. `XCTSkipIf` (XCTest) is deliberately NOT used — the swift-testing-native `.enabled(if:)`
    // trait yields a clean skip without XCTest interop inside a `@Test`. (Plain `//` comments, not a
    // `///` doc comment, so the mandated skip-gate note below stays attached without tripping
    // `orphaned_doc_comment`.)
    //
    // Requires CONVERT_STAGING_SDK_KEY env-var. Set in GitHub Actions environment for manual/release CI gates.
    @Test(
        "live mode: a real-CDN config fetch readies and buckets",
        .enabled(if: ProcessInfo.processInfo.environment["CONVERT_STAGING_SDK_KEY"] != nil)
    )
    func stagingLiveMode() async throws {
        // Only reached WITH the env var (the trait skips otherwise). `#require` keeps the read
        // force-unwrap-free even though the trait already guaranteed presence.
        let key = try #require(
            ProcessInfo.processInfo.environment["CONVERT_STAGING_SDK_KEY"],
            "the .enabled(if:) trait guarantees the key is present when this body runs"
        )

        // Real-CDN configuration: the default config/track base is already
        // `https://cdn-4.convertexperiments.com/api/v1` (ConvertConfiguration.defaultAPIBase), and
        // `networkCacheLevel: .low` appends `_conv_low_cache=1` on the config fetch (CacheLevel.low) to
        // request a lower CDN cache TTL — the staging low-cache semantics.
        let configuration = ConvertConfiguration(sdkKey: key, networkCacheLevel: .low)
        let sdk = ConvertSwiftSDK(configuration: configuration)
        try await sdk.ready()

        // Over the real CDN the config IS fetched and decoded, so a real experience buckets. UNIQUE
        // visitorId for isolation (bd-ilx).
        let context = sdk.createContext(visitorId: "staging-live-\(UUID().uuidString)")
        let variation = await context.runExperience(Self.stagingExperienceKey)
        #expect(variation != nil, "a real staging experience buckets over the live CDN fetch")
    }
}
