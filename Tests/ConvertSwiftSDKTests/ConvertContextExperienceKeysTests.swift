// ConvertContextExperienceKeysTests.swift
// CAP-2 (SPEC-per-call-bucketing-attributes) RED phase — `experienceKeys` narrowing on
// `runFeature`/`runFeatures`. Every call below passing `experienceKeys:` is a compile error
// until GREEN adds the parameter to both signatures, mirroring `ConvertContextFeatureTrackingTests`.
import Testing
import Foundation
@testable import ConvertSwiftSDK

@Suite("ConvertContext runFeature/runFeatures experienceKeys narrowing (CAP-2)")
@MainActor
struct ConvertContextExperienceKeysTests {
    // `nonisolated`: read by `narrowingCases` below, which swift-testing's macro registration
    // accesses outside `@MainActor` isolation.
    private nonisolated static let accountId = "acc-cap2-feat"
    private nonisolated static let projectId = "proj-cap2-feat"
    private nonisolated static let experienceAId = "cap2-exp-a-id"
    private nonisolated static let experienceAKey = "cap2-exp-a-key"
    private nonisolated static let variationAId = "cap2-var-a"
    private nonisolated static let featureAIdInt = 50031
    private nonisolated static let featureAKey = "cap2-feat-a"
    private nonisolated static let experienceBId = "cap2-exp-b-id"
    private nonisolated static let experienceBKey = "cap2-exp-b-key"
    private nonisolated static let variationBId = "cap2-var-b"
    private nonisolated static let featureBIdInt = 50032
    private nonisolated static let featureBKey = "cap2-feat-b"

    private struct SUT: Sendable {
        let sdk: ConvertSwiftSDK
        let sink: MockEventSink
        let decisionFileStore: MockFileStore
    }

    /// One 100%-traffic, no-audience/no-location experience carrying ONE `fullStackFeature`
    /// change bound to `featureIdInt` — the per-carrier fragment ``makeTwoFeatureConfig``
    /// composes twice (SonarQube 3% gate: one shared fragment, not two inlined literals).
    private static func featureExperienceFragment(
        experienceId: String,
        experienceKey: String,
        variationId: String,
        featureIdInt: Int
    ) -> String {
        let change = #"{"id":1,"type":"fullStackFeature","data":{"feature_id":\#(featureIdInt)}}"#
        let variationHead = #"{"id":"\#(variationId)","key":"var-key","traffic_allocation":100,"#
        let variation = variationHead + #""changes":[\#(change)]}"#
        let head = #"{"id":"\#(experienceId)","key":"\#(experienceKey)","type":"a/b","#
        return head + #""audiences":[],"locations":[],"variations":[\#(variation)]}"#
    }

    private static func featureFragment(idInt: Int, key: String) -> String {
        #"{"id":"\#(idInt)","name":"\#(key)-name","key":"\#(key)"}"#
    }

    /// A `ProjectConfig` carrying TWO 100%-traffic experiences, each carrying its OWN distinct
    /// feature (CAP-2's minimal two-experience/two-feature fixture) — any visitor buckets into
    /// BOTH carriers when neither is excluded. `throws` only on malformed JSON.
    private static func makeTwoFeatureConfig() throws -> ProjectConfig {
        let expA = featureExperienceFragment(
            experienceId: experienceAId, experienceKey: experienceAKey,
            variationId: variationAId, featureIdInt: featureAIdInt
        )
        let expB = featureExperienceFragment(
            experienceId: experienceBId, experienceKey: experienceBKey,
            variationId: variationBId, featureIdInt: featureBIdInt
        )
        let featA = featureFragment(idInt: featureAIdInt, key: featureAKey)
        let featB = featureFragment(idInt: featureBIdInt, key: featureBKey)
        let ids = #""account_id":"\#(accountId)","project":{"id":"\#(projectId)"}"#
        let envelope = #"{\#(ids),"experiences":[\#(expA),\#(expB)],"features":[\#(featA),\#(featB)]}"#
        return try JSONDecoder().decode(ProjectConfig.self, from: Data(envelope.utf8))
    }

    /// Builds a READY off-network SDK with an injected `MockEventSink` (the proven
    /// `createContext`-boundary spy) and a `DecisionStore` over its own `MockFileStore`.
    private func makeReadySDK() async throws -> SUT {
        let sink = MockEventSink()
        let decisionFileStore = MockFileStore()
        let sdk = ConvertSwiftSDK(
            configuration: ConvertConfiguration(sdkKey: "cap2-test-key"),
            configProvider: MockConfigProvider.ungated(cached: nil, live: try Self.makeTwoFeatureConfig()),
            eventSink: sink,
            logger: MockLogger(),
            decisionStore: DecisionStore(logger: MockLogger(), fileStore: decisionFileStore)
        )
        try await sdk.ready()
        return SUT(sdk: sdk, sink: sink, decisionFileStore: decisionFileStore)
    }

    /// The REAL on-disk path `DecisionStore.resolveStoreURL()` computes (own copy per the
    /// established per-suite-file wiring precedent — see `PreviewFeatureZeroTraceTests`).
    private func decisionStoreFileURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return appSupport.appendingPathComponent("convert-decision-store.json")
    }

    /// Decodes the `experienceId` of every enqueued `.bucketing` entry via `TrackingEventEntry`'s
    /// own public `Codable` wire shape — no reach into its private payload storage.
    private func enqueuedExperienceIds(_ events: [TrackingEventEntry]) throws -> [String] {
        struct Entry: Decodable { let data: BucketingEventData }
        let encoded = try JSONEncoder().encode(events)
        return try JSONDecoder().decode([Entry].self, from: encoded).map(\.data.experienceId)
    }

    private func status(_ features: [Feature], for key: String) -> FeatureStatus? {
        features.first(where: { $0.key == key })?.status
    }

    // MARK: - Six edge inputs, table-driven (CAP-2)

    struct NarrowingCase: Sendable {
        let slug: String
        let experienceKeys: [String]?
        let expectedEnabled: Set<String>
    }

    nonisolated static let narrowingCases: [NarrowingCase] = [
        NarrowingCase(slug: "nil-absent", experienceKeys: nil, expectedEnabled: [featureAKey, featureBKey]),
        NarrowingCase(slug: "empty-array", experienceKeys: [], expectedEnabled: [featureAKey, featureBKey]),
        NarrowingCase(
            slug: "unknown-among-known", experienceKeys: [experienceAKey, "cap2-unknown-key"],
            expectedEnabled: [featureAKey]
        ),
        NarrowingCase(
            slug: "every-key-unknown", experienceKeys: ["cap2-unknown-1", "cap2-unknown-2"], expectedEnabled: []
        ),
        NarrowingCase(
            slug: "caller-order-swapped", experienceKeys: [experienceBKey, experienceAKey],
            expectedEnabled: [featureAKey, featureBKey]
        ),
        NarrowingCase(
            slug: "duplicate-keys", experienceKeys: [experienceAKey, experienceAKey], expectedEnabled: [featureAKey]
        )
    ]

    /// CAP-2, all six edge inputs: every case must return the SAME count (2, one per declared
    /// feature — narrowing never omits) in the SAME config order (`[A, B]`, never caller order),
    /// with only `expectedEnabled` resolving `.enabled`.
    @Test("runFeatures(experienceKeys:) edge inputs", arguments: narrowingCases)
    func runFeaturesNarrowingEdgeInputs(_ testCase: NarrowingCase) async throws {
        let sut = try await makeReadySDK()
        let context = sut.sdk.createContext(visitorId: "cap2-edge-\(testCase.slug)")
        let results: [Feature] = await context.runFeatures(experienceKeys: testCase.experienceKeys)

        #expect(results.count == 2, "\(testCase.slug): every declared feature is represented, never omitted")
        #expect(
            results.map(\.key) == [Self.featureAKey, Self.featureBKey],
            "\(testCase.slug): config order is preserved regardless of caller order"
        )
        for feature in results {
            let expected: FeatureStatus = testCase.expectedEnabled.contains(feature.key) ? .enabled : .disabled
            #expect(feature.status == expected, "\(testCase.slug): \(feature.key) status")
        }
    }

    // MARK: - CAP-2 success criterion, restated explicitly

    /// The true zero-argument call and an explicit `experienceKeys: nil` call must resolve
    /// identically — pinning that the new default is byte-identical to today's behaviour.
    @Test("runFeatures() with no argument matches runFeatures(experienceKeys: nil)")
    func runFeaturesNoArgumentMatchesExplicitNil() async throws {
        let sut = try await makeReadySDK()
        let context = sut.sdk.createContext(visitorId: "cap2-default-call")
        let noArgument: [Feature] = await context.runFeatures()
        let explicitNil: [Feature] = await context.runFeatures(experienceKeys: nil)
        #expect(noArgument == explicitNil)
    }

    /// `runFeatures(experienceKeys: [A])` reports B `.disabled`, not omitted — CAP-2's structural
    /// claim, isolated from the unknown-key handling the table's third case also exercises.
    @Test("runFeatures(experienceKeys: [A]) reports B disabled, not omitted")
    func runFeaturesSingleKeyExcludesSiblingWithoutOmitting() async throws {
        let sut = try await makeReadySDK()
        let context = sut.sdk.createContext(visitorId: "cap2-single-key")
        let results: [Feature] = await context.runFeatures(experienceKeys: [Self.experienceAKey])
        #expect(results.count == 2)
        #expect(status(results, for: Self.featureAKey) == .enabled)
        #expect(status(results, for: Self.featureBKey) == .disabled)
    }

    /// The singular entry point: excluding B's carrier from `experienceKeys` resolves `runFeature`
    /// for B's own key to a disabled `Feature`.
    @Test("runFeature(bKey, experienceKeys: [A]) returns a disabled Feature")
    func runFeatureSingularExcludedReturnsDisabled() async throws {
        let sut = try await makeReadySDK()
        let context = sut.sdk.createContext(visitorId: "cap2-singular-excluded")
        let feature: Feature = await context.runFeature(Self.featureBKey, experienceKeys: [Self.experienceAKey])
        #expect(feature.status == .disabled)
    }

    /// The excluded experience is upstream of every side effect: no enqueue reaches the spy sink,
    /// and its id never appears in the persisted decision JSON — the included one's id does.
    @Test("the excluded experience receives no sticky write and no enqueue")
    func excludedExperienceProducesNoSideEffects() async throws {
        let sut = try await makeReadySDK()
        let context = sut.sdk.createContext(visitorId: "cap2-spy-visitor")
        let results: [Feature] = await context.runFeatures(experienceKeys: [Self.experienceAKey])
        #expect(status(results, for: Self.featureAKey) == .enabled)

        let enqueuedIds = try enqueuedExperienceIds(await sut.sink.recordedEvents())
        #expect(enqueuedIds == [Self.experienceAId], "only the included experience enqueues")

        let decisionURL = try decisionStoreFileURL()
        let persistedBytes = try #require(await sut.decisionFileStore.contents(at: decisionURL))
        let json = try #require(String(bytes: persistedBytes, encoding: .utf8))
        #expect(json.contains(Self.experienceAId), "the included experience's sticky decision is written")
        #expect(!json.contains(Self.experienceBId), "the excluded experience's id must not persist")
    }

    // MARK: - CAP-1 cross-check: zero enqueue at n=2, not n=1

    /// CAP-1's own suite (`ConvertContextFeatureTrackingTests`) asserts "zero enqueues across
    /// every experience the call evaluates" against a ONE-experience fixture. Reusing THIS
    /// suite's two-carrier fixture closes that n=1 gap for `runFeatures`: the positive control
    /// enqueues BOTH experience ids, so the untracked call's empty set is not an inert fixture.
    @Test("CAP-1: runFeatures(enableTracking: false) enqueues nothing across TWO carrying experiences")
    func runFeaturesUntrackedZeroEnqueueAcrossTwoCarriers() async throws {
        let sut = try await makeReadySDK()

        let untracked: [Feature] = await sut.sdk.createContext(visitorId: "cap1-untracked-two-carriers")
            .runFeatures(enableTracking: false)
        #expect(try enqueuedExperienceIds(await sut.sink.recordedEvents()).isEmpty)

        let tracked: [Feature] = await sut.sdk.createContext(visitorId: "cap1-tracked-two-carriers").runFeatures()
        let enqueuedIds = Set(try enqueuedExperienceIds(await sut.sink.recordedEvents()))
        #expect(
            enqueuedIds == Set([Self.experienceAId, Self.experienceBId]),
            "positive control: a tracked call enqueues BOTH carriers, proving the fixture is not inert"
        )
        #expect(untracked == tracked, "enableTracking must not change either resolved Feature value")
    }

    /// A repeated key in `experienceKeys` is deduplicated: the carrier still enqueues exactly
    /// once, not once per repetition.
    @Test("duplicate experienceKeys enqueue their carrier exactly once")
    func duplicateExperienceKeysEnqueueOnce() async throws {
        let sut = try await makeReadySDK()
        let context = sut.sdk.createContext(visitorId: "cap2-dup-visitor")
        let results: [Feature] = await context.runFeatures(
            experienceKeys: [Self.experienceAKey, Self.experienceAKey]
        )
        #expect(status(results, for: Self.featureAKey) == .enabled)
        let enqueuedIds = try enqueuedExperienceIds(await sut.sink.recordedEvents())
        #expect(enqueuedIds == [Self.experienceAId], "a duplicate key must not double-enqueue")
    }
}
