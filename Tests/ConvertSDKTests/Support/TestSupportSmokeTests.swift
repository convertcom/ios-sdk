// Tests/ConvertSDKTests/Support/TestSupportSmokeTests.swift
//
// RED-phase smoke test for the T0 test-support additions (Epic 5 / Story 5 — full-chain
// payload-structure + concurrency staging tests). This file exercises THREE pieces of
// test-support API that do NOT exist yet, so the test target fails to compile with
// "cannot find ... in scope" / "type ... has no member ..." until the GREEN step adds them —
// that compile failure IS the expected RED state for this TDD cycle:
//
//   1. `URLProtocolStub.recordedRequestCount(for:)` — a per-URL request COUNT accessor added to
//      `Support/URLProtocolStub.swift` (the existing `recordedRequest(for:)` returns only the LAST
//      request for a URL; the new accessor returns HOW MANY hit it, lock-guarded + reset() aware).
//   2. `makeTrackingBatch(events:visitorId:accountId:projectId:)` — a `TestFixtures.swift` factory
//      that wraps entries in ONE `Visitor` (segments `[:]`) inside ONE `TrackingEvent`
//      (`enrichData == false`, `source == "ios-sdk"` are hardcoded by the model's init).
//   3. `makeQueueWithTempFile()` — a `TestFixtures.swift` factory that builds a REAL `EventQueue`
//      over a `CoordinatedFileEventQueueStore` at a UUID-named temp file, plus that temp URL.
//
// `MockEventUploader` (the `EventQueue`'s uploader inside `makeQueueWithTempFile`) ALREADY EXISTS in
// THIS target at `Support/MockBackgroundDelivery.swift` — so GREEN reuses it and need not add one.
//
// ── Why `.serialized` for the stub-counter suite ────────────────────────────────────────────────
// `URLProtocolStub`'s registries (including the new per-URL counter) are PROCESS-GLOBAL. `.serialized`
// orders cases WITHIN a suite, and this suite is nested in the SAME `.serialized` parent the existing
// `URLProtocolStubBackedTests` uses so it runs serially RELATIVE TO the other stub-driving suites —
// otherwise a concurrently-running suite's `reset()` (a global wipe) could clobber this suite's count
// mid-flight (the cross-suite scheduler flake `URLSessionHTTPClientTests.swift` documents). The
// fixture-factory suite (#2/#3) holds NO process-global state, so it is left parallel-safe (unnested).
import Testing
import Foundation
@testable import ConvertSDK

// MARK: - Stub per-URL request counter (RED #1)

/// Serialized RELATIVE TO the other `URLProtocolStub`-driving suites: this suite drives the same
/// process-global stub registries (now including the per-URL counter), so it shares the
/// `URLProtocolStub`-backed `.serialized` parent's scope — see this file's header and
/// `URLSessionHTTPClientTests.swift` for why cross-suite serialization (not just within-suite) is
/// required to avoid a `reset()`-clobbers-another-suite flake.
@Suite("TestSupportStubCounter-backed", .serialized)
enum TestSupportStubCounterBackedTests {
    @Suite("URLProtocolStub.recordedRequestCount", .serialized)
    struct RecordedRequestCountTests {
        /// Endpoint hit THREE times — its counter must read 3.
        static let urlA = URL(string: "https://example.com/count-a")
        /// Endpoint hit ONCE — its counter must read 1, proving the count is per-URL (not global).
        static let urlB = URL(string: "https://example.com/count-b")

        /// Builds an ephemeral session wired to a freshly-reset `URLProtocolStub`, so neither the
        /// install nor the reset block is copy-pasted into the test body (SonarQube new-code
        /// duplication discipline). Mirrors `URLProtocolStubTests.makeStubbedSession`.
        private func makeStubbedSession() -> URLSession {
            URLProtocolStub.reset()
            let configuration = URLSessionConfiguration.ephemeral
            URLProtocolStub.install(into: configuration)
            return URLSession(configuration: configuration)
        }

        /// Fires `count` GET requests to `url` through `session`, ignoring each result (the stub
        /// answers them all). Extracted so the 3×/1× drive loop is written once, not inlined twice.
        private func fire(_ count: Int, to url: URL, on session: URLSession) async throws {
            for _ in 0..<count {
                _ = try await session.data(from: url)
            }
        }

        /// `recordedRequestCount(for:)` counts requests PER URL: after 3 hits to A and 1 to B it
        /// reads 3 / 1, and after `reset()` both read 0 (the NFR21 teardown contract — the counter
        /// is wiped alongside the other registries).
        @Test("recordedRequestCount counts per URL and resets to zero")
        func countsPerURLAndResets() async throws {
            let session = makeStubbedSession()

            guard let urlA = Self.urlA, let urlB = Self.urlB else {
                Issue.record("Failed to construct test URLs")
                return
            }
            // Stub both so the requests are answered (the stub records the request either way, but
            // stubbing keeps the drive on the canned-response path rather than the 404 fallback).
            let emptyBody = Data()
            URLProtocolStub.stub(url: urlA, statusCode: 200, data: emptyBody, headers: [:])
            URLProtocolStub.stub(url: urlB, statusCode: 200, data: emptyBody, headers: [:])

            try await fire(3, to: urlA, on: session)
            try await fire(1, to: urlB, on: session)

            #expect(URLProtocolStub.recordedRequestCount(for: urlA) == 3)
            #expect(URLProtocolStub.recordedRequestCount(for: urlB) == 1)

            URLProtocolStub.reset()
            #expect(URLProtocolStub.recordedRequestCount(for: urlA) == 0)
            #expect(URLProtocolStub.recordedRequestCount(for: urlB) == 0)
        }
    }
}

// MARK: - Fixture factories (RED #2 + #3)

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
