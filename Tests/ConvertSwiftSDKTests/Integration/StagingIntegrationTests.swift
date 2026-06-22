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
// ── Why the STATIC assertion is "ingests + decodes", NOT "returns a non-nil Variation" (EVIDENCED) ──
// A non-nil `Variation` is UNOBTAINABLE from this real staging config offline, for TWO INDEPENDENT
// current-state reasons in Sources/ (both deferred to later stories; neither fixable without editing
// production code, which this story forbids):
//
//   1. The PUBLIC `ConvertSwiftSDK(configData:)` path validates the bytes but does NOT decode them into a
//      `ProjectConfig` — `ConfigStore.validateAndSetConfig` calls `setConfig(nil)` (the structural
//      decode is deferred; see `ConfigValidation.validate(_:Data)` "Story 2.3 adds the real structural
//      decode here"). So `configStore.getSnapshot()` stays `nil` after `ready()`, and
//      `ConvertContext.runExperience` short-circuits to `nil` on the `nil` snapshot — for EVERY key,
//      regardless of attributes. (Empirically confirmed: every experience → nil, every feature →
//      disabled, `runExperiences()` → [].)
//   2. Even decoding `ProjectConfig` directly (bypassing the SDK), the four real experiences degrade
//      out of `ProjectConfig.rawExperiences` — the array `fullExperience(forKey:)` and the bucketing
//      engine read — whenever the generated `ExperienceTypes` enum does not carry their wire
//      `type` (`"a/b_fullstack"`): the per-element decode throws `DecodingError.dataCorrupted` at
//      path `type` and the tolerant `DegradingExperience` wrapper drops each one, so `rawExperiences`
//      is `nil` and `selectVariation` finds no experience for any key. Once the serving-spec regen
//      graduates `"a/b_fullstack"` those experiences are retained instead — but the static assertion
//      below depends on neither outcome (it checks readiness, crash-safety, and the decoded
//      experience COUNT, all of which hold regardless; the nil Variation is reason 1 above).
//
// So this is the story's documented honest fallback: assert the SDK READIES on the real staging bytes
// (the FR7 ingestion path works end-to-end on genuine staging data) AND that `runExperience` is
// crash-safe on real data (AC9 — degrades to `nil`, never throws/crashes), AND — independently — that
// the committed fixture is the GENUINE staging config (its `ProjectConfig` decode recovers the AC5
// account/project coordinates and all four named staging experiences), not a stub. When the deferred
// direct-data structural decode lands, the `runExperience` assertion here flips from `== nil` to a
// non-nil expectation with no other change.
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

        // The public call is crash-safe on real staging data. It degrades to `nil` because the
        // direct-data path does not yet decode the snapshot into a usable config (file header, reason 1)
        // — NOT because of a thrown error. When that deferred decode lands, this flips to a non-nil
        // expectation with no other change to the test.
        let variation = await context.runExperience(Self.stagingExperienceKey)
        // Crash-safe: degrades to nil on the not-yet-decoded direct-data snapshot (file header), not by throwing.
        #expect(variation == nil, "runExperience on the real staging key degrades to nil, not by throwing")

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
