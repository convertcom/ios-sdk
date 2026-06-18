// Tests/ConvertSDKTests/ConvertContextRunFeaturesTests.swift
// `@testable` import (the established pattern — see `ConvertContextRunExperiencesTests.swift`):
// this suite reaches the SDK's INTERNAL surface so a separate test target can see `internal`
// members. It lives in its OWN file (mirroring the run-experiences suite) to keep the feature
// wiring concern separate from the experience wiring concern. The single-feature FIXTURE this
// suite builds on (`makeFeatureConfig`) lives in `Support/TestFixtures.swift` alongside the
// `makeExperienceConfig` / `makeMultiExperienceConfig` builders it twins.
//
// ── Story 4.1 (Epic 4) RED phase ─────────────────────────────────────────────────────────────────
// Asserts the REAL behaviour the WIRING step must produce when it routes the
// `runFeature(_:)` / `runFeatures()` STUBS (which return
// `Feature(id:"", key:key, status:.disabled, variables:[:])` and `[]` UNCONDITIONALLY) to a
// wired `FeatureManager` over the SDK's config snapshot. The contract the wiring implements:
//   * read the config snapshot from the SDK; a `nil` snapshot (pre-ready / no config) → a DISABLED
//     feature (resp. `[]`) WITHOUT touching the manager;
//   * otherwise delegate to `FeatureManager.evaluateFeature(...)` / `evaluateAllFeatures(...)`,
//     enabling a feature the visitor buckets into and surfacing its typed variables; never throw.
//
// Two of these tests FAIL against the current stub — that compile-passing, runtime-failing state is
// the correct RED signal for a WIRING task (cleaner than a compile-fail): the suite calls only the
// EXISTING public surface (`ConvertSDK(...)`, `ready()`, `createContext`, `runFeature`,
// `runFeatures`) plus the new `makeFeatureConfig` fixture, so it COMPILES today; the assertions on an
// `.enabled` feature (with typed variables) and a non-empty result are what the disabled/`[]`-returning
// stubs cannot satisfy.
//   * `runFeaturePreReadyReturnsDisabled` + `runFeaturesPreReadyReturnsEmpty` — PASS today (the stubs
//     return disabled / `[]`, which is ALSO the wired no-snapshot answer), pinning the degraded path
//     across the wiring change.
//   * `runFeatureReadyEnablesCarriedFeature` + `runFeaturesReadyReturnsEnabledFeature` — FAIL today
//     (the stubs return `.disabled` / `[]`), the expected RED signal; the real `FeatureManager`
//     delegation enables the bucketed feature and surfaces its variables.
//
// ── Why RETURN VALUES only (no enqueue-count asserts) ────────────────────────────────────────────
// `ConvertSDK` wires its OWN internal `EventSink` behind `FeatureManager` (which itself delegates
// bucketing — and therefore the `.bucketing` fire — to `ExperienceManager`); the sink is NOT
// injectable through the `createContext` seam (documented for the sibling run-experiences suite). So
// this suite asserts RETURN VALUES only — feature status, typed variables, and the pre-ready-degraded
// path. The bucketing/enqueue contract is covered at the
// `FeatureManager` / `ExperienceManager` level by separate suites; THIS suite owns the public-API
// `runFeature` / `runFeatures` RETURN-VALUE contract.
import Testing
import Foundation
@testable import ConvertSDK

// MARK: - ConvertContext runFeature / runFeatures wiring (Story 4.1)

@Suite("ConvertContext runFeature/runFeatures wiring")
@MainActor
struct ConvertContextRunFeaturesTests {
    /// The `key` of the sole feature `makeFeatureConfig()` carries — declared once so the fixture
    /// default, the `runFeature(_:)` lookups, and the result assertions never re-spell the literal
    /// (SonarQube 3% new-duplicated-lines gate).
    private static let featureKey = "flag-1"

    /// Builds a PRE-READY off-network SDK with NO usable config snapshot: a `MockConfigProvider` canned
    /// `(cached: nil, live: nil)` keeps the SDK off the network AND leaves it with a `nil` snapshot, and
    /// `ready()` is deliberately NOT awaited (mirroring the sibling `runExperiencesPreReadyReturnsEmpty`
    /// build) — the point is the missing snapshot, asserted on a pre-ready context. Centralised so the
    /// two degraded-path tests never copy-paste the provider build (SonarQube 3% gate).
    private func makePreReadySDK() -> ConvertSDK {
        ConvertSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(cached: nil, live: nil)
        )
    }

    /// Builds a READY off-network SDK whose live config carries ONE feature plus the 100%-traffic
    /// experience that enables it, then awaits `ready()` so a subsequent `createContext().runFeature(...)`
    /// sees a NON-`nil` snapshot and resolves the feature through the wired manager. Centralised so the
    /// ready-path tests never copy-paste the provider build + `ready()` await (SonarQube 3% gate).
    /// Mirrors `ConvertContextRunExperiencesTests.makeReadySDK`: a `MockConfigProvider` canned
    /// `(cached: nil, live: <feature config>)` keeps the SDK off the network and resolves `ready()`
    /// non-degraded with that snapshot. `makeFeatureConfig()`'s sole variation is full-traffic, so the
    /// feature enables for ANY `visitorId`.
    private func makeReadySDK() async throws -> ConvertSDK {
        let sdk = ConvertSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(cached: nil, live: try makeFeatureConfig()),
            // Test isolation (bd-ilx): inject a FRESH in-memory `DecisionStore` over a `MockFileStore` so
            // each SDK gets its own sticky-decision state. The default store wires a real on-disk
            // `ApplicationSupportFileStore` at a process-shared path shared with the sibling
            // `ConvertContext*` suites on the SAME `acc-run`/`proj-run`/`user-1` sticky key — so a feature
            // decision persisted here would accrete across runs and risk hydrating stale cross-test state.
            // A per-call `MockFileStore` keeps these decisions in-process. Mirrors the injection precedent
            // across the `ConvertContext*`/conversion/segmentation suites.
            decisionStore: DecisionStore(logger: MockLogger(), fileStore: MockFileStore())
        )
        try await sdk.ready()
        return sdk
    }

    /// AC1/AC12 (degraded): a context whose SDK has NO usable config snapshot resolves `runFeature(_:)`
    /// to a DISABLED feature without throwing. The wired path short-circuits on the absent snapshot
    /// BEFORE reaching the manager (and the current stub also returns a disabled feature), so this
    /// PASSES both today and after wiring — it pins the no-config degraded path across the change.
    @Test("runFeature on a config-less (pre-ready / degraded) context returns a disabled feature")
    func runFeaturePreReadyReturnsDisabled() async throws {
        let result = await makePreReadySDK().createContext().runFeature(Self.featureKey)
        #expect(result.status == .disabled)
    }

    /// AC2/AC12 (degraded): the same config-less context resolves `runFeatures()` to `[]` without
    /// throwing — the wired no-snapshot answer the stub also returns, so this PASSES today and after
    /// wiring, pinning the degraded bulk path.
    @Test("runFeatures on a config-less (pre-ready / degraded) context returns []")
    func runFeaturesPreReadyReturnsEmpty() async throws {
        #expect(await makePreReadySDK().createContext().runFeatures().isEmpty)
    }

    /// RED driver (AC1/AC3/AC16): a READY SDK holding ONE feature carried by a 100%-traffic experience
    /// resolves `runFeature(_:)` to an ENABLED feature whose typed variables come through —
    /// `flag: Bool == true`, `label: String == "hi"` (the values `makeFeatureConfig()` bakes in, typed
    /// by the feature's declared variable types). The current stub returns a DISABLED, variable-less
    /// feature, so the status assertion FAILS today — the expected RED signal; the real `FeatureManager`
    /// delegation makes it pass.
    @Test("runFeature on a ready SDK enables a bucketed feature and surfaces its typed variables")
    func runFeatureReadyEnablesCarriedFeature() async throws {
        let sdk = try await makeReadySDK()
        let result = await sdk.createContext(visitorId: "user-1").runFeature(Self.featureKey)
        #expect(result.status == .enabled, "the wired FeatureManager must enable a bucketed feature")
        #expect(result.variable("flag", as: Bool.self) == true)
        #expect(result.variable("label", as: String.self) == "hi")
    }

    /// RED driver (AC2/AC16): a READY SDK resolves `runFeatures()` to EXACTLY ONE `Feature`,
    /// and that feature is `.enabled` (the bulk form enumerates `config.features` — a single entry here
    /// — and the visitor buckets into its 100%-traffic carrier). The current stub returns `[]`, so both
    /// the count and the status assertions FAIL today — the expected RED signal until the delegation is
    /// wired.
    @Test("runFeatures on a ready SDK returns the one enabled feature")
    func runFeaturesReadyReturnsEnabledFeature() async throws {
        let sdk = try await makeReadySDK()
        let results = await sdk.createContext(visitorId: "user-1").runFeatures()
        #expect(results.count == 1)
        #expect(results.first?.status == .enabled)
    }
}
