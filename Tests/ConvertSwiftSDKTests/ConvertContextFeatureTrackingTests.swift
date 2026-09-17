// Tests/ConvertSwiftSDKTests/ConvertContextFeatureTrackingTests.swift
// `@testable` import (established pattern — see `ConvertContextRunFeaturesTests.swift`): this
// suite lives in its OWN file so the CAP-1 per-call `enableTracking` surface stays separate from
// the Story 4.1 return-value wiring suite it extends.
//
// ── CAP-1 (SPEC-per-call-bucketing-attributes) RED phase ────────────────────────────────────────
// `runFeature`/`runFeatures` take no `enableTracking` parameter today. Every call site below that
// passes `enableTracking:` is a COMPILE error until the GREEN step adds
// `enableTracking: Bool = true` to both signatures (mirroring `runExperience`/`runExperiences`).
// `SegmentationTests.makeReadySDK` proves `MockEventSink` IS injectable at the `createContext`
// boundary (contradicting `ConvertContextRunFeaturesTests`'s stale file-header claim) — reused
// here as the zero-enqueue spy. Sticky-write and `.bucketing`-fire assertions mirror
// `PreviewFeatureZeroTraceTests`'s `MockFileStore`/`subscribeBucketingCount` pattern: iOS keeps
// `emitBucketing` as a SEPARATE engine parameter from `enableTracking` (unlike Android), so
// `enableTracking: false` must suppress ONLY the enqueue — the sticky write and `.bucketing` fire
// still happen.
import Testing
import Foundation
@testable import ConvertSwiftSDK

@Suite("ConvertContext runFeature/runFeatures per-call enableTracking (CAP-1)")
@MainActor
struct ConvertContextFeatureTrackingTests {
    /// The `key` of the sole feature `makeFeatureConfig()` carries (its default) — declared once
    /// so every lookup below never re-spells the literal.
    private static let featureKey = "flag-1"

    /// The `SUT` a case observes: a READY SDK plus the spy sink and the `MockFileStore` backing its
    /// `DecisionStore`, so a test can assert BOTH the enqueue count and the sticky-write outcome.
    private struct SUT: Sendable {
        let sdk: ConvertSwiftSDK
        let sink: MockEventSink
        let decisionFileStore: MockFileStore
    }

    /// Builds a READY off-network SDK over `config` with an injected `MockEventSink` — the proven
    /// `createContext`-boundary spy (`SegmentationTests.makeReadySDK`) — and a `DecisionStore` over
    /// a dedicated `MockFileStore`, so each call site observes its OWN isolated enqueue/sticky state.
    private func makeReadySDK(config: ProjectConfig) async throws -> SUT {
        let sink = MockEventSink()
        let decisionFileStore = MockFileStore()
        let sdk = ConvertSwiftSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(cached: nil, live: config),
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

    /// Subscribes a `.bucketing` fire-count counter on `sdk`'s bus (own copy per the established
    /// per-suite-file wiring precedent — see `PreviewFeatureZeroTraceTests`).
    private func subscribeBucketingCount(on sdk: ConvertSwiftSDK) async -> (LockedBox<Int>, EventListenerToken) {
        let fired = LockedBox<Int>(0)
        let token = await sdk.on(.bucketing) { _ in fired.withLock { $0 += 1 } }
        return (fired, token)
    }

    // MARK: - Zero enqueues + identical return value (CAP-1)

    /// `runFeature(_:enableTracking:false)` enqueues nothing at the `EventSink` and resolves to the
    /// EXACT SAME `Feature` a default (tracked) call resolves — `makeFeatureConfig()`'s sole
    /// variation is 100%-traffic, so any two fresh visitors bucket identically. The tracked call is
    /// the POSITIVE control proving the sink itself works (one enqueue for a fresh bucket).
    @Test("runFeature(enableTracking: false) enqueues nothing and matches a tracked call's Feature")
    func runFeatureUntrackedZeroEnqueueMatchesTracked() async throws {
        let sut = try await makeReadySDK(config: try makeFeatureConfig())

        let untracked: Feature = await sut.sdk.createContext(visitorId: "untracked-visitor")
            .runFeature(Self.featureKey, enableTracking: false)
        #expect(await sut.sink.recordedEvents().isEmpty, "enableTracking: false must enqueue nothing")

        let tracked: Feature = await sut.sdk.createContext(visitorId: "tracked-visitor")
            .runFeature(Self.featureKey)
        #expect(await sut.sink.recordedEvents().count == 1, "positive control: a tracked call enqueues once")

        #expect(untracked == tracked, "enableTracking must not change the resolved Feature value")
    }

    /// The bulk twin: `runFeatures(enableTracking:false)` enqueues nothing across EVERY evaluated
    /// experience and resolves to the same `[Feature]` a default (tracked) call resolves.
    @Test("runFeatures(enableTracking: false) enqueues nothing and matches a tracked call's [Feature]")
    func runFeaturesUntrackedZeroEnqueueMatchesTracked() async throws {
        let sut = try await makeReadySDK(config: try makeFeatureConfig())

        let untracked: [Feature] = await sut.sdk.createContext(visitorId: "untracked-visitor-bulk")
            .runFeatures(enableTracking: false)
        #expect(await sut.sink.recordedEvents().isEmpty, "enableTracking: false must enqueue nothing")

        let tracked: [Feature] = await sut.sdk.createContext(visitorId: "tracked-visitor-bulk").runFeatures()
        #expect(await sut.sink.recordedEvents().count == 1, "positive control: a tracked call enqueues once")

        #expect(untracked == tracked, "enableTracking must not change the resolved [Feature] values")
    }

    // MARK: - Sticky write + .bucketing fire survive enableTracking: false (iOS divergence)

    /// `runFeature(_:enableTracking:false)` suppresses ONLY the enqueue: the sticky decision is
    /// still WRITTEN and `.bucketing` still FIRES (iOS's `emitBucketing` is a separate engine gate
    /// from `enableTracking` — unlike Android, which suppresses its in-process fire too).
    @Test("runFeature(enableTracking: false) still writes the sticky decision and fires .bucketing")
    func runFeatureUntrackedStillPersistsAndFiresBucketing() async throws {
        let sut = try await makeReadySDK(config: try makeFeatureConfig())
        let (bucketingFired, token) = await subscribeBucketingCount(on: sut.sdk)

        let feature: Feature = await sut.sdk.createContext(visitorId: "untracked-persist-visitor")
            .runFeature(Self.featureKey, enableTracking: false)
        #expect(feature.status == .enabled, "the feature still resolves normally")

        await MainActor.run { }
        #expect(bucketingFired.get == 1, "the in-process .bucketing fire is NOT suppressed by enableTracking")

        let decisionURL = try decisionStoreFileURL()
        #expect(
            await sut.decisionFileStore.contents(at: decisionURL) != nil,
            "the sticky decision write is NOT suppressed by enableTracking"
        )
        #expect(await sut.sink.recordedEvents().isEmpty, "the outbound enqueue is still suppressed")
        await sut.sdk.off(token)
    }

    /// The bulk twin of the above, for `runFeatures(enableTracking:false)`.
    @Test("runFeatures(enableTracking: false) still writes the sticky decision and fires .bucketing")
    func runFeaturesUntrackedStillPersistsAndFiresBucketing() async throws {
        let sut = try await makeReadySDK(config: try makeFeatureConfig())
        let (bucketingFired, token) = await subscribeBucketingCount(on: sut.sdk)

        let features: [Feature] = await sut.sdk.createContext(visitorId: "untracked-persist-visitor-bulk")
            .runFeatures(enableTracking: false)
        #expect(features.first?.status == .enabled, "the feature still resolves normally")

        await MainActor.run { }
        #expect(bucketingFired.get == 1, "the in-process .bucketing fire is NOT suppressed by enableTracking")

        let decisionURL = try decisionStoreFileURL()
        #expect(
            await sut.decisionFileStore.contents(at: decisionURL) != nil,
            "the sticky decision write is NOT suppressed by enableTracking"
        )
        #expect(await sut.sink.recordedEvents().isEmpty, "the outbound enqueue is still suppressed")
        await sut.sdk.off(token)
    }

    // MARK: - Default unchanged from today (regression lock, no enableTracking argument)

    /// The DEFAULT (no `enableTracking` argument) is unchanged: a fresh bucket enqueues exactly
    /// once, and a subsequent STICKY RECALL for the same visitor enqueues nothing further while
    /// returning the identical `Feature`.
    @Test("the default runFeature enqueues once when newly bucketed, nothing on a sticky recall")
    func runFeatureDefaultEnqueuesOnceThenStickyRecallEnqueuesNothing() async throws {
        let sut = try await makeReadySDK(config: try makeFeatureConfig())
        let context = sut.sdk.createContext(visitorId: "sticky-recall-visitor")

        let first = await context.runFeature(Self.featureKey)
        #expect(await sut.sink.recordedEvents().count == 1, "a fresh bucket enqueues exactly once")

        let second = await context.runFeature(Self.featureKey)
        #expect(await sut.sink.recordedEvents().count == 1, "a sticky recall enqueues nothing further")
        #expect(first == second, "a sticky recall returns the identical Feature")
    }
}
