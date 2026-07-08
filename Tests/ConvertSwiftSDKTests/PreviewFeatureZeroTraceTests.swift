// Tests/ConvertSwiftSDKTests/PreviewFeatureZeroTraceTests.swift
//
// RED phase (qs-02 IOS-fix2 — FEATURE-path zero-trace hardening, decision-audit round-2 finding).
// Spec: `_bmad-output/planning-artifacts/2026-06-09-convert-ios-sdk/qs-02-experiment-preview.md`,
// contract §2 "Zero-trace (hard requirement)"; AC6 (zero trace) with AC7 (isolation) as a companion
// regression guard. Lives in its OWN file (mirroring `ConvertContextRunFeaturesTests`'s documented
// precedent of splitting the feature-wiring concern into its own suite file) — also keeps
// `PreviewZeroTraceTests.swift` under SwiftLint's `file_length` gate rather than growing it past 400
// lines.
//
// ── The gap this suite documents (does not exist yet — this is why it is RED) ──────────────────────
// `PreviewZeroTraceTests` already covers the EXPERIENCE path (`runExperience`/`runExperiences`), the
// CONVERSION path (`trackConversion`), and the SEGMENT setters (`setDefaultSegments`/
// `setCustomSegments`) — all four already thread the per-context `previewActive` gate. The FEATURE
// path (`ConvertContext.runFeature`/`runFeatures`, `Sources/ConvertSwiftSDK/ConvertContext.swift:466`,
// `:509`) carries NO reference to `previewState` at all: it delegates straight to
// `FeatureManager.evaluateFeature`/`evaluateAllFeatures`
// (`Sources/ConvertSwiftSDKCore/Experience/FeatureManager.swift:83`,`:149`), which call
// `experienceManager.selectVariation(...)` with `enableTracking: true` HARDCODED
// (`FeatureManager.swift:107-116`) and pass NO `persistDecision` argument — so it takes
// `ExperienceManager.selectVariation`'s own default, `true`
// (`Sources/ConvertSwiftSDKCore/Experience/ExperienceManager.swift:159`). So a preview-active context
// running a feature whose carrying experience buckets a FRESH visitor still fires the sticky-decision
// WRITE (`decisionStore.saveDecision` → `DecisionStore.swift:126-147`'s `fileStore.write` at `:146`)
// AND the `.bucketing` enqueue (`BucketingManager.swift:126-128`) — violating contract §2's "ALL
// visitor-state persistence writes are disabled" / "ALL tracking is disabled ... overrides all three
// tracking layers."
//
// ── Why a REAL `EventQueue` + REAL `CoordinatedFileEventQueueStore` (mirrors the sibling suite) ─────
// Same rationale as `PreviewZeroTraceTests` (see its file header): AC6 requires the on-disk queue
// store be exercised, so this suite wires a REAL `EventQueue` over a REAL
// `CoordinatedFileEventQueueStore` at a UUID-named temp file through a `MockEventUploader` spy. The
// SUT here is an intentional, self-contained copy of that wiring shape (own queue/decision-store/SDK
// construction) rather than widening the sibling file's `private` access — each `ConvertContext*`/
// `Preview*` suite in this codebase already owns its own SDK/store construction (compare
// `ConvertContextRunFeaturesTests`'s `makeReadySDK` to `PreviewZeroTraceTests`'s `makeSUT`: analogous,
// independently-owned wiring per suite file, not a per-CASE copy-paste WITHIN one file — the shape the
// SonarQube 3% new-duplicated-lines gate this codebase honors actually targets), so this is the
// established cross-suite pattern, not a new duplication source.
import Testing
import Foundation
@testable import ConvertSwiftSDK

@Suite("Preview zero-trace hardening — FEATURE path (qs-02 IOS-fix2)")
@MainActor
struct PreviewFeatureZeroTraceTests {
    // MARK: - Fixed fixture identifiers (single owner each — SonarQube 3% new-duplicated-lines gate)

    private static let accountId = "acc-preview-feat"
    private static let projectId = "proj-preview-feat"
    private static let targetExperienceId = "9301"
    private static let targetKey = "target-key"
    private static let targetForcedVariationId = "t-var"
    private static let featureKey = "feature-flag"
    private static let featureIdInt = 20031
    private static let featureExperienceId = "9302"
    private static let featureExperienceKey = "feature-carrier-key"
    private static let featureVariationId = "feat-var-pz"

    // MARK: - Config fixture

    /// A `ProjectConfig` carrying an UNRELATED preview TARGET experience (two variations — `"t-ctrl"`
    /// at 100% traffic, the forced one at 0%, so a natural bucket would NEVER select it — mirrors
    /// `PreviewZeroTraceTests.makeConfig()`'s target shape) PLUS a SEPARATE `features`-carrying
    /// experience this suite drives via `runFeatures()`. The feature-carrying shape mirrors
    /// `Support/TestFixtures.swift:264`'s `makeFeatureConfig()` (INTEGER change `id`, INTEGER
    /// `data.feature_id` bound to the STRING `features[].id` by
    /// `String(feature_id) == feature.id` — same load-bearing trap documented there): its SOLE
    /// variation is 100%-traffic, so it buckets for ANY visitor hash — always a FRESH,
    /// never-before-decided bucket against each test's own isolated `DecisionStore`/`MockFileStore`
    /// (no sticky hit is possible). `throws` only on malformed JSON (`ProjectConfig.init(from:)`
    /// degrades per-field, so this shape never throws).
    private static func makeConfig() throws -> ProjectConfig {
        let targetVariations = #"[{"id":"t-ctrl","key":"control","traffic_allocation":100},"#
            + #"{"id":"\#(targetForcedVariationId)","key":"variant","traffic_allocation":0}]"#
        let target = #"{"id":"\#(targetExperienceId)","key":"\#(targetKey)","type":"a/b","#
            + #""audiences":[],"locations":[],"variations":\#(targetVariations)}"#
        let variablesData = #"{"flag":true}"#
        let variableTypes = #"[{"key":"flag","type":"boolean"}]"#
        let changeData = #""data":{"feature_id":\#(featureIdInt),"variables_data":\#(variablesData)}"#
        let change = #"{"id":1,"type":"fullStackFeature",\#(changeData)}"#
        let featureVariationHead = #"{"id":"\#(featureVariationId)","key":"feat-var-key","#
            + #""traffic_allocation":100,"#
        let featureVariation = featureVariationHead + #""changes":[\#(change)]}"#
        let featureExperienceHead = #"{"id":"\#(featureExperienceId)","key":"\#(featureExperienceKey)","#
            + #""type":"a/b","#
        let featureExperience = featureExperienceHead
            + #""audiences":[],"locations":[],"variations":[\#(featureVariation)]}"#
        let featureHead = #"{"id":"\#(featureIdInt)","name":"\#(featureKey)-name","key":"\#(featureKey)","#
        let feature = featureHead + #""variables":\#(variableTypes)}"#
        let ids = #""account_id":"\#(accountId)","project":{"id":"\#(projectId)"}"#
        let envelope = #"{\#(ids),"experiences":[\#(target),\#(featureExperience)],"features":[\#(feature)]}"#
        return try JSONDecoder().decode(ProjectConfig.self, from: Data(envelope.utf8))
    }

    /// The REAL on-disk path `DecisionStore.resolveStoreURL()` computes
    /// (`DecisionStore.swift:296-307` — a `private static` method, so this replicates its documented
    /// Application-Support-first algorithm rather than reaching it). Deterministic within a process,
    /// so it is a stable key into each test's OWN fresh `MockFileStore` instance.
    private static func decisionStoreFileURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return appSupport.appendingPathComponent("convert-decision-store.json")
    }

    // MARK: - SUT

    /// Mirrors `PreviewZeroTraceTests.SUT` — a READY SDK wired to a REAL `EventQueue` over a REAL
    /// `CoordinatedFileEventQueueStore` at a UUID-named temp file (shipping through a
    /// `MockEventUploader` spy), and the SDK's canonical `DecisionStore` over a `MockFileStore` spy.
    private struct SUT: Sendable {
        let sdk: ConvertSwiftSDK
        let queue: EventQueue
        let queueStoreURL: URL
        let queueStore: CoordinatedFileEventQueueStore
        let uploader: MockEventUploader
        let decisionFileStore: MockFileStore
    }

    /// Builds an isolated SUT — see `PreviewZeroTraceTests.makeSUT()` for the identical wiring
    /// rationale (this suite owns its own copy so it stays independent of that file's `private`
    /// members and both files stay under the `file_length` gate).
    private func makeSUT() async throws -> SUT {
        let queueStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let queueStore = CoordinatedFileEventQueueStore(fileURL: queueStoreURL, logger: NoopLogger())
        let uploader = MockEventUploader()
        let queue = EventQueue(
            accountId: Self.accountId,
            projectId: Self.projectId,
            uploader: uploader,
            eventBus: EventBus(),
            store: queueStore
        )
        let decisionFileStore = MockFileStore()
        let decisionStore = DecisionStore(logger: NoopLogger(), fileStore: decisionFileStore)
        let sdk = ConvertSwiftSDK(
            configuration: ConvertConfiguration(sdkKey: "zero-trace-feature-key"),
            configProvider: MockConfigProvider.ungated(cached: nil, live: try Self.makeConfig()),
            eventSink: queue,
            logger: NoopLogger(),
            decisionStore: decisionStore
        )
        try await sdk.ready()
        return SUT(
            sdk: sdk,
            queue: queue,
            queueStoreURL: queueStoreURL,
            queueStore: queueStore,
            uploader: uploader,
            decisionFileStore: decisionFileStore
        )
    }

    // MARK: - AC6 gap: the FEATURE path is NOT currently preview-gated (RED)

    /// Confirms preview is genuinely active first (a forced `runExperience` result on the UNRELATED
    /// preview-target experience — `runFeatures()` never touches that experience), then calls
    /// `runFeatures()` for a feature carried by a SEPARATE 100%-traffic, never-before-decided
    /// experience and asserts: the feature STILL resolves `.enabled` (coherent rendering, contract
    /// §2 — this is NOT an early-return-to-disabled test) while ZERO writes ever reach the shared
    /// `MockFileStore` spy and ZERO `.bucketing` entries ever reach the on-disk queue file / the
    /// uploader. Expected to FAIL (RED) today, per the file-header gap.
    @Test("preview-active context's runFeatures produces zero trace and still resolves the feature (AC6 gap, IOS-fix2)")
    func previewContextFeaturePathProducesZeroTrace() async throws {
        let sut = try await makeSUT()
        defer { try? FileManager.default.removeItem(at: sut.queueStoreURL) }
        let context = sut.sdk.createContext(visitorId: "preview-feature-visitor")

        await context.setPreview(experienceId: Self.targetExperienceId, variationId: Self.targetForcedVariationId)
        let forced = await context.runExperience(Self.targetKey)
        #expect(forced?.id == Self.targetForcedVariationId, "preview must be genuinely active for this context")

        let features = await context.runFeatures()
        #expect(
            features.first(where: { $0.key == Self.featureKey })?.status == .enabled,
            "coherent rendering: the feature must still resolve correctly under preview (contract §2)"
        )

        await sut.queue.persistBeforeBackground()
        let persisted = try await sut.queueStore.load()
        #expect(persisted.isEmpty, "zero-trace: runFeatures must not persist a .bucketing event under preview")
        #expect(
            !FileManager.default.fileExists(atPath: sut.queueStoreURL.path),
            "zero-trace: no queue file was ever written by runFeatures under preview"
        )

        await sut.queue.flush()
        #expect(await sut.uploader.callCount == 0, "zero-trace: no batch from runFeatures must ever reach the uploader")

        let decisionURL = try Self.decisionStoreFileURL()
        #expect(
            await sut.decisionFileStore.contents(at: decisionURL) == nil,
            "zero-trace: runFeatures must not write a sticky decision under preview"
        )
    }

    // MARK: - AC7 companion: a non-preview context's feature path still tracks + persists normally

    /// Companion regression guard (AC7, F-171): the SAME feature-carrying config, on a NON-preview
    /// context, must still persist the sticky decision AND enqueue the `.bucketing` event exactly as
    /// today — proving the eventual GREEN fix scopes the gate to `previewActive` rather than changing
    /// the feature path's tracking behaviour at large (`runFeature`/`runFeatures` stay parameterless
    /// per F-171 — no `enableTracking` argument is added). A FRESH, ISOLATED `SUT` (own queue/decision
    /// store), matching `PreviewZeroTraceTests.nonPreviewContextStillTracksAndPersists()`'s isolation
    /// rationale. Expected to PASS today (pins the CURRENT correct non-preview behaviour before GREEN
    /// touches the feature path).
    @Test("a non-preview context's runFeatures still enqueues and persists normally (AC7 regression guard)")
    func nonPreviewContextFeaturePathStillPersists() async throws {
        let sut = try await makeSUT()
        defer { try? FileManager.default.removeItem(at: sut.queueStoreURL) }
        let context = sut.sdk.createContext(visitorId: "normal-feature-visitor")

        let features = await context.runFeatures()
        #expect(features.first(where: { $0.key == Self.featureKey })?.status == .enabled)

        await sut.queue.persistBeforeBackground()
        let persisted = try await sut.queueStore.load()
        #expect(!persisted.isEmpty, "a non-preview context's runFeatures must still reach the on-disk queue")

        await sut.queue.flush()
        #expect(
            await sut.uploader.callCount > 0,
            "a non-preview context's runFeatures batch must still reach the uploader"
        )

        let decisionURL = try Self.decisionStoreFileURL()
        #expect(
            await sut.decisionFileStore.contents(at: decisionURL) != nil,
            "a non-preview context's runFeatures must still write a sticky decision"
        )
    }
}
