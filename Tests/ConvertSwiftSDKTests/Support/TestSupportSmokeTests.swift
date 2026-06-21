// Tests/ConvertSwiftSDKTests/Support/TestSupportSmokeTests.swift
//
// RED-phase smoke test for the T0 test-support additions (Epic 5 / Story 5 — full-chain
// payload-structure + concurrency staging tests). This file exercises the two PARALLEL-SAFE
// fixture-factory pieces of test-support API that do NOT exist yet, so the test target fails to
// compile with "cannot find ... in scope" / "type ... has no member ..." until the GREEN step adds
// them — that compile failure IS the expected RED state for this TDD cycle:
//
//   1. `makeTrackingBatch(events:visitorId:accountId:projectId:)` — a `TestFixtures.swift` factory
//      that wraps entries in ONE `Visitor` (segments `[:]`) inside ONE `TrackingEvent`
//      (`enrichData == false`, `source == "ios-sdk"` are hardcoded by the model's init).
//   2. `makeQueueWithTempFile()` — a `TestFixtures.swift` factory that builds a REAL `EventQueue`
//      over a `CoordinatedFileEventQueueStore` at a UUID-named temp file, plus that temp URL.
//
// `MockEventUploader` (the `EventQueue`'s uploader inside `makeQueueWithTempFile`) ALREADY EXISTS in
// THIS target at `Support/MockBackgroundDelivery.swift` — so GREEN reuses it and need not add one.
//
// ── Why these suites are parallel-safe (no `.serialized`) ───────────────────────────────────────
// `makeTrackingBatch` and `makeQueueWithTempFile` touch NO process-global state — each
// `makeQueueWithTempFile` uses its OWN UUID-named temp file — so these cases may run in parallel
// with everything else.
//
// The third T0 addition — `URLProtocolStub.recordedRequestCount(for:)` — DOES drive process-global
// stub state, so its smoke test (`RecordedRequestCountTests`) lives in
// `Tests/ConvertSwiftSDKTests/Adapters/URLSessionHTTPClientTests.swift`, nested under the one shared
// `URLProtocolStub-backed` `.serialized` parent alongside the other stub-driving suites. That is the
// ONLY placement that serializes it RELATIVE TO those suites (two SEPARATE top-level `.serialized`
// parents still run in PARALLEL, so a sibling suite's `reset()` global wipe would otherwise clobber
// its tally mid-flight). See that file's header for the cross-suite serialization mechanism.
import Testing
import Foundation
@testable import ConvertSwiftSDK

// MARK: - Fixture factories (RED #1 + #2)

/// Parallel-safe (NOT nested under the `.serialized` stub parent): `makeTrackingBatch` and
/// `makeQueueWithTempFile` touch NO process-global state — each `makeQueueWithTempFile` uses its OWN
/// UUID-named temp file — so these cases may run in parallel with everything else.
@Suite("TestSupportFixtureFactories")
struct TestSupportFixtureFactoriesTests {
    /// `makeTrackingBatch(...)` wraps the given entries in ONE `Visitor` (segments `{}`) inside ONE
    /// `TrackingEvent` stamped with the account/project, with `enrichData`/`source` forced to the
    /// model's hardcoded invariants (`false` / `"ios-sdk"`). Built with one bucketing + one
    /// conversion entry so the 2-event count is meaningful.
    @Test("makeTrackingBatch wraps entries in one TrackingEvent with one visitor")
    func makeTrackingBatchBuildsEnvelope() async throws {
        let bucketing = TrackingEventEntry.bucketing(
            BucketingEventData(experienceId: "e1", variationId: "v1")
        )
        let conversion = TrackingEventEntry.conversion(
            ConversionEventData(goalId: "g1")
        )

        let event = makeTrackingBatch(
            events: [bucketing, conversion],
            visitorId: "vis1",
            accountId: "10035569",
            projectId: "10034190"
        )

        #expect(event.accountId == "10035569")
        #expect(event.projectId == "10034190")
        #expect(event.enrichData == false)
        #expect(event.source == "ios-sdk")
        #expect(event.visitors.count == 1)

        let visitor = try #require(event.visitors.first)
        #expect(visitor.visitorId == "vis1")
        #expect(visitor.events.count == 2)
    }

    /// `makeQueueWithTempFile()` yields a REAL `EventQueue` over a `CoordinatedFileEventQueueStore` at
    /// a UUID temp file: enqueuing one bucketing entry then `drain()`ing returns exactly one
    /// `TrackingEvent` envelope carrying that single event. The temp file is removed in `defer` so the
    /// case leaves no artifact behind (NFR21 — no state leaks).
    @Test("makeQueueWithTempFile drains the enqueued entry as one envelope")
    func makeQueueWithTempFileDrainsEntry() async throws {
        let (queue, url) = await makeQueueWithTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        await queue.enqueue(
            .bucketing(BucketingEventData(experienceId: "e1", variationId: "v1")),
            for: "vis1",
            segments: nil
        )
        let drained = await queue.drain()

        #expect(drained.count == 1)
        let envelope = try #require(drained.first)
        let visitor = try #require(envelope.visitors.first)
        #expect(visitor.visitorId == "vis1")
        #expect(visitor.events.count == 1)
        let entry = try #require(visitor.events.first)
        #expect(entry.eventType == "bucketing")
    }
}
