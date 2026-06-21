// Tests/ConvertSwiftSDKCoreTests/Experience/FeatureManagerTests.swift
// Unit tests for `FeatureManager` evaluation (Epic 4 / Story 1): a feature resolves through the
// `ExperienceManager` pipeline — ENABLED iff the visitor buckets into a variation whose
// `fullStackFeature` change carries it (`String(change.feature_id) == feature.id`), with its
// `variables` read from that change's `variables_data` typed by the matching
// `features[].variables[].type`. An unknown key, an uncarried feature, or an ineligible carrier all
// yield `Feature.disabled(key:)`; `evaluateAllFeatures` over a config with no features yields
// `[]`; the feature path itself invents/fires NO SystemEvent (it delegates the `.bucketing` fire to
// `ExperienceManager`). The `Feature` MODEL (the `variable(_:as:)` accessor, `disabled(key:)`,
// `Codable`/`Equatable`) is tested separately in `Models/FeatureTests.swift`.

import Foundation
import Testing
@testable import ConvertSwiftSDKCore

@Suite("FeatureManager")
struct FeatureManagerTests {
    //
    // ── Test-hygiene invariants (SonarQube 3% `new_duplicated_lines_density`) ─────────────────
    //   * Every subject goes through `makeFeatureManager`; every per-feature call through `evaluate`
    //     (the fixed account/project/visitor triple is centralized in `FeatureIds`, mirroring
    //     `ExperienceManagerTests.Ids`); every config through a `ProjectConfigFixtures` builder — no
    //     test body re-wires the manager, re-spells the id triple, or re-inlines a wire block.
    //   * The EventBus capture helpers (`BucketingCapture`, `subscribeBucketing`, `drain`) MIRROR
    //     `ExperienceManagerTests` verbatim. They are re-declared (not shared) because that file's
    //     copies are `private` to its suite and so invisible here; kept minimal to stay under the gate.
    //   * No wall-clock asserts — fired-or-not is read after a `MainActor` executor barrier (`drain`).

    /// The account/project/visitor triple every FeatureManager scenario evaluates under — centralized
    /// so the id arguments are written once (mirrors ``ExperienceManagerTests`` `Ids`).
    private enum FeatureIds {
        static let account = "a"
        static let project = "p"
        static let visitor = "v1"
    }

    /// What a `.bucketing` EventBus subscriber records: a fire count (the feature path must add ZERO).
    /// A named struct (not a tuple — `large_tuple`) so a ``LockedBox`` can hold it for the `@Sendable`
    /// callback to mutate. Mirrors ``ExperienceManagerTests`` `BucketingCapture`.
    private struct BucketingCapture {
        var fireCount = 0
    }

    /// Builds the subject over REAL ExperienceManager collaborators (the 5-arg init — `eventSink` goes
    /// to the `BucketingManager`, NOT the EM) wired to the passed (or default) `eventBus` + `logger`,
    /// so no test re-wires the dependency graph inline (SonarQube 3% gate). The `eventBus` is the SAME
    /// instance a test subscribes to for the "no event fired" assertion.
    private func makeFeatureManager(
        eventBus: EventBus = EventBus(),
        logger: Logger = MockLogger()
    ) -> FeatureManager {
        let experienceManager = ExperienceManager(
            ruleManager: RuleManager(logger: MockLogger()),
            bucketingManager: BucketingManager(eventSink: MockEventSink(), logger: MockLogger()),
            decisionStore: DecisionStore(logger: MockLogger(), fileStore: MockFileStore()),
            eventBus: eventBus,
            logger: MockLogger()
        )
        return FeatureManager(experienceManager: experienceManager, logger: logger)
    }

    /// Invokes `evaluateFeature` with the shared ``FeatureIds`` triple and per-scenario knobs, so the
    /// long argument list (and the fixed account/project/visitor literals) is written exactly once.
    private func evaluate(
        _ subject: FeatureManager,
        key: String,
        in config: ProjectConfig,
        attributes: [String: String] = [:],
        locationProperties: [String: String] = [:]
    ) async -> Feature {
        await subject.evaluateFeature(
            key: key,
            in: config,
            visitorId: FeatureIds.visitor,
            accountId: FeatureIds.account,
            projectId: FeatureIds.project,
            attributes: attributes,
            locationProperties: locationProperties
        )
    }

    /// Invokes `evaluateAllFeatures` with the shared ``FeatureIds`` triple (the bulk twin of
    /// ``evaluate(_:key:in:attributes:locationProperties:)``).
    private func evaluateAll(
        _ subject: FeatureManager,
        in config: ProjectConfig,
        attributes: [String: String] = [:],
        locationProperties: [String: String] = [:]
    ) async -> [Feature] {
        await subject.evaluateAllFeatures(
            in: config,
            visitorId: FeatureIds.visitor,
            accountId: FeatureIds.account,
            projectId: FeatureIds.project,
            attributes: attributes,
            locationProperties: locationProperties
        )
    }

    /// Lets already-dispatched `MainActor` callbacks run before assertions read the capture — a pure
    /// executor barrier (`EventBus.fire` delivers each callback as a `Task { @MainActor in … }`), no
    /// wall-clock wait. Mirrors ``ExperienceManagerTests`` `drain()`.
    private func drain() async {
        await MainActor.run { }
    }

    /// Subscribes a `.bucketing` counter on `eventBus`, returning the ``LockedBox`` the `@Sendable`
    /// callback writes — the caller evaluates, `await drain()`s, then reads `.get.fireCount`. Mirrors
    /// ``ExperienceManagerTests`` `subscribeBucketing(on:)`.
    private func subscribeBucketing(on eventBus: EventBus) async -> LockedBox<BucketingCapture> {
        let box = LockedBox(BucketingCapture())
        _ = await eventBus.on(.bucketing) { _ in
            box.withLock { $0.fireCount += 1 }
        }
        return box
    }

    /// The raw-JSON `variables_data` body the enabled feature carries — one value per the five
    /// `FeatureVariable` branches (values are raw JSON; their type is set by ``allVariableTypesJSON``).
    private static let allVariablesDataJSON = """
    {"flag":true,"label":"hi","limit":42,"ratio":3.14,"payload":{"k":1}}
    """

    /// The matching `features[].variables` type list for ``allVariablesDataJSON`` — pairs each
    /// variable name with its declared type (the vocabulary the feature path decodes `variables_data`
    /// against): boolean / string / integer / float / json.
    private static let allVariableTypesJSON = """
    [{"key":"flag","type":"boolean"},{"key":"label","type":"string"},\
    {"key":"limit","type":"integer"},{"key":"ratio","type":"float"},\
    {"key":"payload","type":"json"}]
    """

    // MARK: AC1/AC3 — unknown key → disabled

    /// A key absent from `config.features` resolves to a disabled feature with no variables (the
    /// lookup misses before any carrier/bucketing work). The config here HAS a feature, just not the
    /// requested key, so this also pins "wrong key ≠ first feature".
    @Test("AC1/AC3 — an unknown feature key resolves to disabled with no variables")
    func unknownFeatureKeyIsDisabled() async throws {
        let config = try ProjectConfigFixtures.featureCarriedByVariationConfig(
            featureKey: "flag-1", featureIdInt: 10031
        )
        let result = await evaluate(makeFeatureManager(), key: "no-such", in: config)

        #expect(result.status == .disabled, "an unknown feature key must resolve to disabled")
        #expect(result.variables.isEmpty, "a disabled feature carries no variables")
    }

    // MARK: AC2 — evaluateAllFeatures over an empty config

    /// A config with no `features` (and no experiences) yields `[]` from `evaluateAllFeatures` —
    /// nothing to evaluate.
    @Test("AC2 — evaluateAllFeatures over a config with no features returns []")
    func evaluateAllFeaturesEmptyConfigReturnsEmpty() async throws {
        let config = try ProjectConfigFixtures.makeConfig(experiencesJSON: "[]")
        let results = await evaluateAll(makeFeatureManager(), in: config)

        #expect(results.isEmpty, "no features must yield no results")
    }

    // MARK: AC3 — bucketed carrier → enabled; ineligible carrier → disabled

    /// The feature `"flag-1"` is carried by a sole full-traffic (`alloc: 100`) variation, so the
    /// visitor always buckets into the carrier ⇒ the feature is ENABLED.
    @Test("AC3 — a feature carried by a bucketed variation is enabled")
    func carriedFeatureBucketsEnabled() async throws {
        let config = try ProjectConfigFixtures.featureCarriedByVariationConfig(
            featureKey: "flag-1", featureIdInt: 10031, alloc: 100
        )
        let result = await evaluate(makeFeatureManager(), key: "flag-1", in: config)

        #expect(result.status == .enabled, "a bucketed carrier must enable the feature")
    }

    /// The SAME feature carried by a variation whose `traffic_allocation` is `0` never buckets, so the
    /// carrier is ineligible ⇒ the feature is DISABLED even though a carrier exists in the config.
    @Test("AC3 — a feature whose carrier never buckets (alloc 0) is disabled")
    func carriedFeatureIneligibleDisabled() async throws {
        let config = try ProjectConfigFixtures.featureCarriedByVariationConfig(
            featureKey: "flag-1", featureIdInt: 10031, alloc: 0
        )
        let result = await evaluate(makeFeatureManager(), key: "flag-1", in: config)

        #expect(result.status == .disabled, "an ineligible carrier must leave the feature disabled")
        #expect(result.variables.isEmpty, "a disabled feature carries no variables")
    }

    // MARK: AC3/AC14 — feature with no carrier → disabled

    /// The feature `"orphan"` exists in `config.features` but NO variation's change references its id
    /// (the only change binds to a different feature_id), so it has no carrier ⇒ DISABLED, no
    /// variables — the carrier-absent branch, distinct from the ineligible-carrier branch above.
    @Test("AC3/AC14 — a feature with no carrying variation is disabled")
    func uncarriedFeatureIsDisabled() async throws {
        let config = try ProjectConfigFixtures.featureCarriedByVariationConfig(
            featureKey: "orphan", featureIdInt: 10031, carried: false
        )
        let result = await evaluate(makeFeatureManager(), key: "orphan", in: config)

        #expect(result.status == .disabled, "a feature with no carrier must be disabled")
        #expect(result.variables.isEmpty, "an uncarried feature carries no variables")
    }

    // MARK: AC5–AC10 — five-type variable population on the enabled feature

    /// The enabled `"flag-1"` feature carries all five variable types in `variables_data`, typed by a
    /// matching `features[].variables` list. After it resolves ENABLED, each typed accessor returns the
    /// decoded value (one body asserting all five accessors — a single block, NOT five duplicated
    /// cases, so it adds nothing to CPD). The `json` value is returned as `Data` and must deserialize
    /// back to the original object.
    @Test("AC5–AC10 — an enabled feature populates all five typed variables from variables_data")
    func enabledFeaturePopulatesAllFiveVariableTypes() async throws {
        let config = try ProjectConfigFixtures.featureCarriedByVariationConfig(
            featureKey: "flag-1",
            featureIdInt: 10031,
            variablesDataJSON: Self.allVariablesDataJSON,
            variablesTypesJSON: Self.allVariableTypesJSON,
            alloc: 100
        )
        let result = await evaluate(makeFeatureManager(), key: "flag-1", in: config)

        #expect(result.status == .enabled, "the carrier buckets, so the feature must be enabled")
        #expect(result.variable("flag", as: Bool.self) == true, "boolean variable must decode")
        #expect(result.variable("label", as: String.self) == "hi", "string variable must decode")
        #expect(result.variable("limit", as: Int.self) == 42, "integer variable must decode")
        #expect(result.variable("ratio", as: Double.self) == 3.14, "float variable must decode")

        // `json` is carried as raw `Data`; it must deserialize back to the original `{"k":1}` object.
        let payload = try #require(
            result.variable("payload", as: Data.self),
            "json variable must be present as Data"
        )
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Int]
        #expect(object == ["k": 1], "the json variable's Data must deserialize to the original object")
    }

    // MARK: AC15 — the feature path fires NO SystemEvent when nothing buckets

    /// On a config where NOTHING buckets (no features, no experiences), `evaluateFeature` resolves
    /// disabled WITHOUT the feature path firing any `.bucketing` SystemEvent — proving FeatureManager
    /// invents/fires no event of its own (and the delegated ExperienceManager, having nothing to
    /// bucket, fires nothing either). Subscribes the SAME `EventBus` the subject is built over, drains
    /// the `MainActor` queue, then asserts a zero fire count.
    @Test("AC15 — the feature path fires no .bucketing system event on a config where nothing buckets")
    func featurePathFiresNoSystemEvent() async throws {
        let bus = EventBus()
        let subject = makeFeatureManager(eventBus: bus)
        let fired = await subscribeBucketing(on: bus)
        let config = try ProjectConfigFixtures.makeConfig(experiencesJSON: "[]")

        let result = await evaluate(subject, key: "anything", in: config)
        await drain()

        #expect(result.status == .disabled, "with nothing to bucket the feature resolves disabled")
        #expect(
            fired.get.fireCount == 0,
            "the feature path must fire no .bucketing system event when nothing buckets"
        )
    }
}
