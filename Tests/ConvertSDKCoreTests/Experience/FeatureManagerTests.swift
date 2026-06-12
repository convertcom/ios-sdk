// Tests/ConvertSDKCoreTests/Experience/FeatureManagerTests.swift
// RED-phase contract for the `BucketedFeature` MODEL completion (Epic 4 / Story 1).
//
// This file will later also hold `FeatureManager` tests (added by a downstream agent); for
// now it carries ONLY the model-level tests below, under `@Suite("FeatureManager")`.
//
// WHAT MAKES THIS SUITE RED:
//   The implementation work (done NEXT, not here) ADDS to `BucketedFeature.swift`:
//     1. `Codable` + `Equatable` conformances on `FeatureStatus`, `FeatureVariable`, and
//        `BucketedFeature`.
//     2. A `static func disabled(key:) -> BucketedFeature` factory.
//   None of those exist yet, so the `disabledFactory`, `equatable…`, and `codable…` tests
//   reference symbols/conformances that don't compile — the correct RED outcome. The two
//   accessor tests (`typedAccessorMatrix`, `accessorReturnsNilOn…`) exercise only the
//   already-implemented `variable(_:as:)` and MAY pass; they're pinned here so the model's
//   accessor contract (AC5–AC11) is covered alongside the RED additions.
import Foundation
import Testing
@testable import ConvertSDKCore

@Suite("FeatureManager")
struct FeatureManagerTests {
    // MARK: - Shared construction

    /// Builds a multi-variable `BucketedFeature` whose `status` is the only knob, so the
    /// Equatable/Codable tests don't re-spell the same `variables:` dictionary inline (keeps
    /// new-duplicated-lines density under the SonarQube gate). Carries one of each of the five
    /// variable cases so the Codable test forces every `FeatureVariable` branch through encode
    /// AND decode.
    static func makeFeature(status: FeatureStatus) -> BucketedFeature {
        BucketedFeature(
            id: "feat-1",
            key: "checkout-flow",
            status: status,
            variables: [
                "flag": .boolean(true),
                "label": .string("hello"),
                "limit": .integer(42),
                "ratio": .float(3.14),
                "payload": .json(Data("{\"k\":1}".utf8))
            ]
        )
    }

    // MARK: - Typed accessor matrix (parameterized — AC5–AC10)

    /// One accessor case: a variable name, the `FeatureVariable` stored under it, and a
    /// `@Sendable` predicate that calls the matching typed accessor and confirms it returns the
    /// expected value. The check is boxed in a thunk (the `ConvertValueTests` idiom) so a SINGLE
    /// parameterized body covers all five heterogeneous `T.Type` assertions without re-spelling
    /// the accessor ladder — and so the case stays `Sendable`, which swift-testing's `arguments:`
    /// requires. A named struct (not a tuple) keeps the `large_tuple` lint rule satisfied.
    struct AccessorCase: Sendable {
        let label: String
        let name: String
        let variable: FeatureVariable
        let check: @Sendable (BucketedFeature) -> Bool
    }

    static let accessorCases: [AccessorCase] = [
        AccessorCase(
            label: "bool-var → Bool.self",
            name: "bool-var",
            variable: .boolean(true),
            check: { $0.variable("bool-var", as: Bool.self) == true }
        ),
        AccessorCase(
            label: "str-var → String.self",
            name: "str-var",
            variable: .string("hello"),
            check: { $0.variable("str-var", as: String.self) == "hello" }
        ),
        AccessorCase(
            label: "int-var → Int.self",
            name: "int-var",
            variable: .integer(42),
            check: { $0.variable("int-var", as: Int.self) == 42 }
        ),
        AccessorCase(
            label: "float-var → Double.self",
            name: "float-var",
            variable: .float(3.14),
            check: { $0.variable("float-var", as: Double.self) == 3.14 }
        ),
        AccessorCase(
            label: "json-var → Data.self",
            name: "json-var",
            variable: .json(Data("{\"k\":1}".utf8)),
            check: { $0.variable("json-var", as: Data.self) == Data("{\"k\":1}".utf8) }
        )
    ]

    @Test("variable(_:as:) returns the typed value for each of the five variable cases", arguments: accessorCases)
    func typedAccessorMatrix(testCase: AccessorCase) {
        let feature = BucketedFeature(
            id: "f",
            key: "f",
            status: .enabled,
            variables: [testCase.name: testCase.variable]
        )
        #expect(
            testCase.check(feature),
            "\(testCase.label): typed accessor did not return the stored value"
        )
    }

    // MARK: - Accessor nil paths (AC11)

    @Test("variable(_:as:) returns nil on a type mismatch and on an unknown name")
    func accessorReturnsNilOnMismatchOrMiss() {
        let feature = BucketedFeature(
            id: "f",
            key: "f",
            status: .enabled,
            variables: ["bool-var": .boolean(true)]
        )
        // Type mismatch: the value is `.boolean`, requested as `Int`.
        #expect(feature.variable("bool-var", as: Int.self) == nil)
        // Unknown name: no such key in `variables`.
        #expect(feature.variable("absent", as: String.self) == nil)
    }

    // MARK: - disabled(key:) factory (AC12 — RED: factory does not exist yet)

    @Test("disabled(key:) builds a disabled feature with an empty id and no variables")
    func disabledFactory() {
        let feature = BucketedFeature.disabled(key: "any")
        #expect(feature.status == .disabled)
        #expect(feature.variables.isEmpty)
        #expect(feature.key == "any")
        #expect(feature.id == "")
        #expect(feature.variable("any", as: Bool.self) == nil)
    }

    // MARK: - Equatable (AC4 — RED: Equatable conformance does not exist yet)

    @Test("BucketedFeature is Equatable across status, key, and all variable cases")
    func equatableHonoursValueAndStatus() {
        let a = Self.makeFeature(status: .enabled)
        let b = Self.makeFeature(status: .enabled)
        let differingStatus = Self.makeFeature(status: .disabled)

        // Two identically-built values compare equal — forces `Equatable` on
        // `BucketedFeature`, `FeatureVariable` (the `variables` values), and `FeatureStatus`.
        #expect(a == b)
        // A value differing only in `status` compares unequal.
        #expect(a != differingStatus)
    }

    // MARK: - Codable (AC4 — RED: Codable conformance does not exist yet)

    @Test("BucketedFeature round-trips through JSON encode/decode unchanged")
    func codableRoundTrips() throws {
        let original = Self.makeFeature(status: .enabled)
        // Internal Swift<->Swift symmetry: encode then decode and require value equality.
        // The wire shape is unconstrained here (no JS parity assertion) — only that
        // encode/decode is a faithful round-trip, which forces `Codable` on all three types.
        let data = try CodableTestHelpers.sortedKeysEncoder.encode(original)
        let decoded = try JSONDecoder().decode(BucketedFeature.self, from: data)
        #expect(decoded == original)
    }

    // MARK: ════════════════════════════════════════════════════════════════════════════════════
    // MARK: FeatureManager evaluation (Epic 4 / Story 1)
    // MARK: ════════════════════════════════════════════════════════════════════════════════════
    //
    // ── Expected RED state ───────────────────────────────────────────────────────────────────
    // `FeatureManager` does NOT exist yet (its implementation is the NEXT step, not this one), so
    // every `@Test` below references an undeclared type and the file is EXPECTED to fail to COMPILE
    // with "cannot find 'FeatureManager' in scope" (from `makeFeatureManager` / `evaluate`). All the
    // collaborators these tests wire — `ExperienceManager`, `RuleManager`, `BucketingManager`,
    // `DecisionStore`, `EventBus`, `BucketedFeature`, the `ProjectConfigFixtures` builders — already
    // exist, so that missing-`FeatureManager` error is the ONLY one expected.
    //
    // ── Contract pinned here ─────────────────────────────────────────────────────────────────
    // A feature is ENABLED iff the visitor buckets into a variation whose `fullStackFeature` change
    // carries it (`String(change.feature_id) == feature.id`); its `variables` are read from that
    // change's `variables_data`, each typed by the matching `features[].variables[].type`. An unknown
    // key, an uncarried feature, or an ineligible carrier (the variation never buckets) all yield
    // `BucketedFeature.disabled(key:)` — `status == .disabled`, empty `variables`. `evaluateAllFeatures`
    // over a config with no features yields `[]`. The feature path itself invents/fires NO SystemEvent
    // (on a config where nothing buckets, even the delegated `ExperienceManager` fires nothing).
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
    ) async -> BucketedFeature {
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
    ) async -> [BucketedFeature] {
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
