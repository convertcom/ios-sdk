// Tests/ConvertSwiftSDKTests/PreviewZeroTraceTests.swift
//
// RED phase (qs-02 IOS-6 — zero-trace hardening, AC6 HARD GATE). Spec:
// `_bmad-output/planning-artifacts/2026-06-09-convert-ios-sdk/qs-02-experiment-preview.md`,
// contract §2 "Zero-trace (hard requirement)"; AC6 (zero trace) with AC7 (isolation) as a
// companion regression guard.
//
// ── What GREEN must add (does not exist yet — this is why this suite is RED) ───────────────────
// A per-context `previewActive` gate (per the bd task ai-driven-product-dev-y1ke and the IOS-6
// readiness assessment in `work/2026-07-08-ios-sdk-experiment-preview/workflow-state.yaml`) that:
//   * ANDs into the `enableTracking` value `ConvertContext.runExperience`/`runExperiences` thread
//     into `experienceManager.selectVariation`/`selectVariations`
//     (`Sources/ConvertSwiftSDK/ConvertContext.swift:304`/`:430`) — so `BucketingManager`'s
//     enableTracking-gated enqueue (`Sources/ConvertSwiftSDKCore/Bucketing/BucketingManager.swift:126-128`,
//     `:214-216`) never fires for ANY experience run on a preview-active context, not just the
//     forced target.
//   * Adds an EARLY guard in `ConvertContext.trackConversion`
//     (`Sources/ConvertSwiftSDK/ConvertContext.swift:586-661`) BEFORE
//     `decisionStore.markGoalTriggeredIfNeeded(goalId:forVisitorKey:)` (`:618`, which itself
//     unconditionally persists via `DecisionStore.swift:181`'s `fileStore.write` even on a FIRST
//     trigger) and `return`s, so the dedup persist AND both `eventSink.enqueue` call sites (`:642`,
//     `:659`) never run under preview.
//   * Suppresses `ExperienceManager.selectVariation`'s sticky-decision WRITE
//     (`Sources/ConvertSwiftSDKCore/Experience/ExperienceManager.swift:184-186`,
//     `decisionStore.saveDecision` → `DecisionStore.swift:126-147`'s `fileStore.write` at `:146`)
//     for OTHER (non-target) experiences run on a preview-active context — via a threaded
//     `persistDecision: Bool` or a per-context scratch `DecisionStore` (GREEN's call; this suite is
//     agnostic to which shape is picked, since it only asserts the OBSERVABLE zero-write contract
//     through the injected `MockFileStore` spy).
// None of this exists today: `runExperience`/`runExperiences` gate ONLY on
// `sdk.isTrackingEnabled() && enableTracking` (the SDK-shared / per-call flags — not
// `previewActive`), and `ExperienceManager.selectVariation`'s `saveDecision` call has no gate at
// all. So EVERY assertion below observes real production traffic today and is expected to FAIL.
//
// ── Why a REAL `EventQueue` + REAL `CoordinatedFileEventQueueStore` (not `MockEventSink`) ──────
// AC6 explicitly requires the ON-DISK queue store be exercised (bd task design note: "Exercise the
// coordinated-file queue store for the on-disk assertion"). Mirrors the wiring
// `Support/TestFixtures.swift:648-660` (`makeQueueWithTempFileAndUploader`) already establishes: a
// REAL `EventQueue` over a REAL `CoordinatedFileEventQueueStore` at a UUID-named temp file, shipping
// through a `MockEventUploader` spy — this suite builds that same shape inline (not via the shared
// factory) so it also keeps a direct handle on the `CoordinatedFileEventQueueStore` for the
// `load()` on-disk assertion (the shared factory only returns the queue + its file URL).
//
// ── "Background-flush transition" — a documented, narrower choice than the full `LifecycleObserver`
// dance (flagged for the report) ─────────────────────────────────────────────────────────────────
// The only existing test that drives an actual app-lifecycle background transition is
// `Tests/ConvertSwiftSDKTests/Lifecycle/LifecycleObserverTests.swift` (posts
// `UIApplication.willResignActiveNotification`/`didBecomeActiveNotification` to an isolated
// `NotificationCenter` feeding a real `LifecycleObserver`). That observer's engine does exactly two
// things on a background transition (`Sources/ConvertSwiftSDK/Lifecycle/LifecycleObserver.swift:75,89`):
// `await eventQueue.persistBeforeBackground()` then (on foreground) `await eventQueue.flush()` — both
// `package`-accessible `EventQueue` entry points (`Sources/ConvertSwiftSDKCore/Event/EventQueue.swift:243,357`)
// already called DIRECTLY by an existing test
// (`Tests/ConvertSwiftSDKTests/Integration/FullChainIntegrationTests.swift:288`, `await sut.queue.flush()`).
// This suite calls those SAME two methods directly on the SAME real
// `EventQueue` the SDK is wired with, rather than re-standing-up the full `LifecycleObserver` +
// `MockBackgroundSessionManager` + UIKit `beginBackgroundTask` machinery: it exercises the identical
// production code path the observer drives, with a deterministic `await` (no notification-driven
// detached `Task` to race), which is what lets the on-disk zero-entries assertion run BEFORE `flush()`
// clears the store. `enqueueUpload` itself is NOT asserted here — `LifecycleEngine.handleBackground()`
// calls it UNCONDITIONALLY on every backgrounding regardless of preview state (an existing, orthogonal
// Story 5.3 design fact, not something IOS-6 changes) — so "zero background-session uploads" is
// asserted as "the file a background upload would stream is empty / was never written", per the AC6
// design note's own phrasing ("nothing enqueued implies nothing to upload").
import Testing
import Foundation
@testable import ConvertSwiftSDK

@Suite("Preview zero-trace hardening (qs-02 IOS-6, AC6)")
@MainActor
struct PreviewZeroTraceTests {
    // MARK: - Fixed fixture identifiers (single owner each — SonarQube 3% new-duplicated-lines gate)

    private static let accountId = "acc-preview-zt"
    private static let projectId = "proj-preview-zt"
    private static let targetExperienceId = "9101"
    private static let targetKey = "target-key"
    private static let targetForcedVariationId = "t-var"
    private static let otherKey = "other-key"
    private static let otherVariationId = "o-var"
    private static let goalKey = "purchase-goal"
    private static let goalId = "goal-pz"

    // MARK: - Config fixture

    /// A `ProjectConfig` carrying the preview TARGET experience (two variations — `"t-ctrl"` at 100%
    /// traffic, `"t-var"` at 0%, so a natural bucket would NEVER select the forced one), a sibling
    /// `"other-key"` experience (one 100%-traffic variation, buckets EVERY visitor deterministically —
    /// same shape as `TestFixtures.makeExperienceConfig`), and one resolvable goal — all under the
    /// SAME `account_id`/`project.id` so the sticky store key is well-formed. `throws` only on
    /// malformed JSON (`ProjectConfig.init(from:)` degrades per-field, so this shape never throws).
    private static func makeConfig() throws -> ProjectConfig {
        let targetVariations = #"[{"id":"t-ctrl","key":"control","traffic_allocation":100},"#
            + #"{"id":"\#(targetForcedVariationId)","key":"variant","traffic_allocation":0}]"#
        let target = #"{"id":"\#(targetExperienceId)","key":"\#(targetKey)","type":"a/b","#
            + #""audiences":[],"locations":[],"variations":\#(targetVariations)}"#
        let otherVariation = #"{"id":"\#(otherVariationId)","key":"control","traffic_allocation":100}"#
        let other = #"{"id":"9102","key":"\#(otherKey)","type":"a/b","#
            + #""audiences":[],"locations":[],"variations":[\#(otherVariation)]}"#
        let goal = #"{"id":"\#(goalId)","key":"\#(goalKey)","name":"Purchase","type":"advanced"}"#
        let ids = #""account_id":"\#(accountId)","project":{"id":"\#(projectId)"}"#
        let envelope = #"{\#(ids),"experiences":[\#(target),\#(other)],"goals":[\#(goal)]}"#
        return try JSONDecoder().decode(ProjectConfig.self, from: Data(envelope.utf8))
    }

    /// The REAL on-disk path `DecisionStore.resolveStoreURL()` computes (`DecisionStore.swift:296-307`
    /// — a `private static` method, so this replicates its documented Application-Support-first
    /// algorithm rather than reaching it). Deterministic within a process, so it is a stable key into
    /// each test's OWN fresh `MockFileStore` instance (no cross-test collision — a `MockFileStore` is
    /// an in-memory actor keyed by `URL.absoluteString`, never a real file on disk).
    private static func decisionStoreFileURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return appSupport.appendingPathComponent("convert-decision-store.json")
    }

    // MARK: - SUT

    /// Everything one test drives and asserts on: a READY SDK wired to a REAL `EventQueue` over a
    /// REAL `CoordinatedFileEventQueueStore` at a UUID-named temp file (shipping through a
    /// `MockEventUploader` spy), and the SDK's canonical `DecisionStore` over a `MockFileStore` spy —
    /// so both the "in-memory queue" / "on-disk queue" / "background-session upload" surfaces AND the
    /// "sticky-bucketing write" surface are independently observable. A named struct (not a tuple)
    /// keeps the `large_tuple` lint rule satisfied. `Sendable` — every member is `Sendable`
    /// (`ConvertSwiftSDK`, the `EventQueue`/`CoordinatedFileEventQueueStore`/`DecisionStore` actors,
    /// the `MockEventUploader`/`MockFileStore` actors, `URL`).
    private struct SUT: Sendable {
        let sdk: ConvertSwiftSDK
        let queue: EventQueue
        let queueStoreURL: URL
        let queueStore: CoordinatedFileEventQueueStore
        let uploader: MockEventUploader
        let decisionFileStore: MockFileStore
    }

    /// Builds an isolated SUT: a fresh UUID-named temp file backs a REAL
    /// `CoordinatedFileEventQueueStore` feeding a REAL `EventQueue` (over a `MockEventUploader`
    /// spy — mirrors `TestFixtures.makeQueueWithTempFileAndUploader`'s wiring inline so this file
    /// also keeps a direct `queueStore` handle for the on-disk `load()` assertion), and a fresh
    /// `DecisionStore` over a `MockFileStore` spy. Single construction path so no case re-inlines the
    /// queue/store wiring (SonarQube 3% gate).
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
            configuration: ConvertConfiguration(sdkKey: "zero-trace-key"),
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

    // MARK: - `.bucketing` observer capture (qs-02 Fix 1 — mirrors
    // `ConversionTrackingTests.firesConversionSystemEvent`'s `sdk.on(.conversion)` + `LockedBox`
    // pattern, applied to `.bucketing`, so no test invents a new bus-observation mechanism)

    /// Subscribes a `.bucketing` fire-count counter on `sdk`'s bus, returning the counter and the
    /// token to `off` when the caller is done. `EventBus.fire` delivers each callback as an
    /// independent `MainActor` task, so callers `await MainActor.run { }` (the same barrier
    /// `ConversionTrackingTests` uses) before reading the count. Centralized so no test in this file
    /// re-spells the subscribe wiring (SonarQube 3% gate).
    private func subscribeBucketingCount(on sdk: ConvertSwiftSDK) async -> (LockedBox<Int>, EventListenerToken) {
        let fired = LockedBox<Int>(0)
        let token = await sdk.on(.bucketing) { _ in fired.withLock { $0 += 1 } }
        return (fired, token)
    }

    // MARK: - AC6: zero trace across the full preview lifecycle incl. a background transition

    /// The AC6 hard gate: on a PREVIEW context, run the forced target, run a SIBLING (non-previewed)
    /// experience, attempt a conversion, then drive the SAME background-persist / foreground-flush
    /// steps a real backgrounding triggers (see the file header for why these are called directly
    /// rather than through the full `LifecycleObserver` + `NotificationCenter` dance). Asserts all
    /// four zero-trace surfaces the spec names: nothing ever reaches the uploader (in-memory +
    /// background-session upload), nothing is ever persisted to the on-disk event-queue file, and
    /// nothing is ever written to the sticky-decision file. `other?.id == otherVariationId` is the
    /// AC7-adjacent "coherent rendering" companion: the sibling experience must still DECIDE normally
    /// even though nothing about that decision may be tracked or persisted. Also asserts (qs-02 Fix 1,
    /// JS parity — `context.ts`'s `if (!this._preview)` guard around every `SystemEvents.BUCKETING`
    /// emit) that the `.bucketing` OBSERVER event never fires for EITHER the target or the sibling
    /// while preview is active.
    @Test("preview lifecycle incl. background transition produces zero tracking + zero sticky writes")
    func previewLifecycleProducesZeroTrace() async throws {
        let sut = try await makeSUT()
        defer { try? FileManager.default.removeItem(at: sut.queueStoreURL) }
        let context = sut.sdk.createContext(visitorId: "preview-visitor")
        let (bucketingFired, bucketingToken) = await subscribeBucketingCount(on: sut.sdk)

        await context.setPreview(experienceId: Self.targetExperienceId, variationId: Self.targetForcedVariationId)

        let forced = await context.runExperience(Self.targetKey)
        #expect(forced?.id == Self.targetForcedVariationId, "the preview target must still force correctly")

        let other = await context.runExperience(Self.otherKey)
        #expect(
            other?.id == Self.otherVariationId,
            "a non-previewed sibling must still decide normally (coherent rendering, contract §2)"
        )

        await MainActor.run { }
        #expect(
            bucketingFired.get == 0,
            "zero-trace (Fix 1): the .bucketing observer event must not fire for the target or the sibling"
        )

        await context.trackConversion(Self.goalKey, goalData: [.amount: .double(9.99)])

        // Background transition: the SAME two `package`-accessible EventQueue entry points
        // `LifecycleObserver` calls on `willResignActive`/`didBecomeActive`
        // (`LifecycleObserver.swift:75,89`) — called directly here for a deterministic `await`
        // (see file header). `persistBeforeBackground()` is a no-op when the buffer is empty
        // (`EventQueue.swift:244`'s `guard !buffer.isEmpty else { return }`), so checking the
        // on-disk store IMMEDIATELY after it — before `flush()` — proves whether anything EVER
        // reached the in-memory buffer in the first place.
        await sut.queue.persistBeforeBackground()
        let persisted = try await sut.queueStore.load()
        #expect(persisted.isEmpty, "zero-trace: nothing must ever be persisted to the on-disk event queue")
        #expect(
            !FileManager.default.fileExists(atPath: sut.queueStoreURL.path),
            "zero-trace: no queue file was ever written — nothing exists for a background upload to stream"
        )

        // Foreground-recovery flush: drains disk-first-merged-with-buffer and ships through the
        // uploader. If nothing was ever buffered or persisted, this must be a genuine no-op.
        await sut.queue.flush()
        #expect(await sut.uploader.callCount == 0, "zero-trace: no batch must ever reach the uploader")
        #expect(await sut.uploader.uploadedBatches().isEmpty)

        // Zero sticky-bucketing writes: `ExperienceManager.selectVariation`'s `saveDecision` call
        // (`ExperienceManager.swift:184-186`) and `trackConversion`'s `markGoalTriggeredIfNeeded`
        // (`ConvertContext.swift:618`, itself persisting via `DecisionStore.swift:181`) both write
        // through the SAME injected `MockFileStore` — so a `nil` there proves NEITHER ever fired.
        let decisionURL = try Self.decisionStoreFileURL()
        #expect(
            await sut.decisionFileStore.contents(at: decisionURL) == nil,
            "zero-trace: no sticky-decision / goal-dedup write must ever land on disk"
        )
        await sut.sdk.off(bucketingToken)
    }

    // MARK: - AC6: the bulk `runExperiences` path must also produce zero `.bucketing` observer events

    /// Companion to ``previewLifecycleProducesZeroTrace()`` for the BULK path (qs-02 Fix 1): under
    /// preview, `runExperiences()` must still resolve BOTH the forced target (appended back per
    /// `ConvertContext.runExperiences(enableTracking:)`'s contract) and the sibling (coherent
    /// rendering), while firing ZERO `.bucketing` observer events for either.
    @Test("preview-active runExperiences produces zero .bucketing observer events (Fix 1, bulk path)")
    func previewRunExperiencesProducesZeroBucketingEvents() async throws {
        let sut = try await makeSUT()
        defer { try? FileManager.default.removeItem(at: sut.queueStoreURL) }
        let context = sut.sdk.createContext(visitorId: "preview-bulk-visitor")
        let (bucketingFired, bucketingToken) = await subscribeBucketingCount(on: sut.sdk)

        await context.setPreview(experienceId: Self.targetExperienceId, variationId: Self.targetForcedVariationId)
        let results = await context.runExperiences()

        #expect(
            results.first(where: { $0.experienceKey == Self.targetKey })?.id == Self.targetForcedVariationId,
            "the forced target must still be present in the bulk results"
        )
        #expect(
            results.first(where: { $0.experienceKey == Self.otherKey })?.id == Self.otherVariationId,
            "the sibling must still decide normally (coherent rendering, contract §2)"
        )

        await MainActor.run { }
        #expect(
            bucketingFired.get == 0,
            "zero-trace (Fix 1): runExperiences must not fire the .bucketing observer event under preview"
        )
        await sut.sdk.off(bucketingToken)
    }

    // MARK: - AC7 companion: a non-preview context must still track + persist normally

    /// Regression guard (bd task design note + prompt requirement): a context that NEVER calls
    /// `setPreview` must decide, ENQUEUE, and PERSIST exactly as before — proving whatever gate GREEN
    /// adds is keyed on the PER-CONTEXT `previewActive` flag, not the SDK-shared tracking state (which
    /// would silently break every non-preview caller). A FRESH, ISOLATED `SUT` (own queue/decision
    /// store) — sharing this SUT with the zero-trace test above would let a genuine enqueue collide
    /// with that test's "must stay empty" assertions. Also asserts (Fix 1 regression guard) that the
    /// `.bucketing` OBSERVER event still fires normally when preview is NOT active — proving the new
    /// `emitBucketing` gate is keyed on `previewActive`, not a blanket suppression.
    @Test("a concurrent non-preview context still enqueues and persists normally (AC7 regression guard)")
    func nonPreviewContextStillTracksAndPersists() async throws {
        let sut = try await makeSUT()
        defer { try? FileManager.default.removeItem(at: sut.queueStoreURL) }
        let context = sut.sdk.createContext(visitorId: "normal-visitor")
        let (bucketingFired, bucketingToken) = await subscribeBucketingCount(on: sut.sdk)

        let other = await context.runExperience(Self.otherKey)
        #expect(other?.id == Self.otherVariationId)
        await MainActor.run { }
        #expect(bucketingFired.get == 1, "a non-preview .bucketing observer event must still fire normally")
        await sut.sdk.off(bucketingToken)
        await context.trackConversion(Self.goalKey, goalData: [.amount: .double(9.99)])

        await sut.queue.persistBeforeBackground()
        let persisted = try await sut.queueStore.load()
        #expect(!persisted.isEmpty, "a non-preview context's events must still reach the on-disk queue")

        await sut.queue.flush()
        #expect(await sut.uploader.callCount > 0, "a non-preview context's batch must still reach the uploader")

        let decisionURL = try Self.decisionStoreFileURL()
        #expect(
            await sut.decisionFileStore.contents(at: decisionURL) != nil,
            "a non-preview context's sticky decision / goal-dedup mark must still be written"
        )
    }

    // MARK: - AC6 gap: segment setters are NOT currently preview-gated (RED)

    /// `ConvertContext.setDefaultSegments`/`setCustomSegments` (`ConvertContext.swift:678`,`:708`)
    /// delegate to `SegmentsManager.setDefaultSegments`/`setCustomSegments`
    /// (`SegmentsManager.swift:34`,`:60`), which delegate to `DecisionStore.mergeSegments`
    /// (`DecisionStore.swift:232`) and `DecisionStore.appendCustomSegments` (`DecisionStore.swift:267`)
    /// — BOTH of which unconditionally `fileStore.write` (`DecisionStore.swift:258`,`:287`) with NO
    /// preview gate today, unlike the sticky-decision write and the goal-dedup write this suite's
    /// first test already covers. Confirms preview is genuinely active first (a forced `runExperience`
    /// result), then calls both segment setters and asserts ZERO writes reached the shared
    /// `MockFileStore` spy — expected to FAIL (RED) until GREEN adds the same per-context
    /// `previewActive` gate to these two call sites.
    @Test("preview-active context's segment setters produce zero sticky-store writes (AC6 gap)")
    func previewContextSegmentSettersProduceZeroTrace() async throws {
        let sut = try await makeSUT()
        defer { try? FileManager.default.removeItem(at: sut.queueStoreURL) }
        let context = sut.sdk.createContext(visitorId: "preview-segments-visitor")

        await context.setPreview(experienceId: Self.targetExperienceId, variationId: Self.targetForcedVariationId)
        let forced = await context.runExperience(Self.targetKey)
        #expect(forced?.id == Self.targetForcedVariationId, "preview must be genuinely active for this context")

        await context.setDefaultSegments(["country": "US"])
        await context.setCustomSegments(["vip"])

        let decisionURL = try Self.decisionStoreFileURL()
        #expect(
            await sut.decisionFileStore.contents(at: decisionURL) == nil,
            "zero-trace: setDefaultSegments/setCustomSegments must not write to the sticky-decision store under preview"
        )
    }

    /// Companion regression guard (AC7): the SAME two setters, called on a NON-preview context, must
    /// still persist — proving the future fix scopes the gate to `previewActive`, not a blanket
    /// disable of the segment write path. A FRESH, ISOLATED `SUT`, matching
    /// ``nonPreviewContextStillTracksAndPersists()``'s isolation rationale above.
    @Test("a non-preview context's segment setters still persist normally (AC7 regression guard)")
    func nonPreviewContextSegmentSettersStillPersist() async throws {
        let sut = try await makeSUT()
        defer { try? FileManager.default.removeItem(at: sut.queueStoreURL) }
        let context = sut.sdk.createContext(visitorId: "normal-segments-visitor")

        await context.setDefaultSegments(["country": "US"])
        await context.setCustomSegments(["vip"])

        let decisionURL = try Self.decisionStoreFileURL()
        #expect(
            await sut.decisionFileStore.contents(at: decisionURL) != nil,
            "a non-preview context's segment setters must still write to the sticky-decision store"
        )
    }
}
