// Tests/ConvertSDKTests/Integration/FullChainIntegrationTests.swift
//
// FR67 full-chain integration suite — the Epic 5 / Story 5 RELEASE-GATE wiring test. Drives the REAL
// public `ConvertSDK` API (createContext → runExperience → runFeature → setDefaultSegments →
// trackConversion×2) and proves the produced events travel the REAL delivery chain — a REAL
// `EventQueue` over a REAL `URLSessionEventUploader` over a REAL `URLSessionHTTPClient(session:)` whose
// session has `URLProtocolStub` installed — landing as ONE canonical POST envelope on the track URL.
// This file touches NO Sources/.
//
// ── AC1 REINTERPRETED (binding readiness-gate decision Q1=a) ──────────────────────────────────────
// Story AC1 literally asks for "exactly two HTTP requests (one GET /config + one POST /track)" from a
// single `ConvertSDK` instance. That is IMPOSSIBLE test-only: `ConvertSDK` has NO URLSession injection
// seam (its inits hardcode `URLSessionHTTPClient(sdkVersion:)`), and adding a production seam is
// FORBIDDEN for a test-only story. So config is supplied OUT-OF-BAND via the existing internal-init
// `configProvider` seam (no live transport needed for the GET), and the test asserts the REAL track
// POST. The config-GET-to-stub path is already covered by `ConfigFetchServiceTests`, so dropping that
// sub-assertion loses no coverage. Dev Agent Record: "AC1 reinterpreted — config supplied out-of-band
// (no URLSession seam exists); one POST /track asserted; GET-to-stub covered by ConfigFetchServiceTests."
//
// ── What the asserted ONE POST proves (the full chain, in one envelope) ───────────────────────────
// The SDK's injected `eventSink` is a REAL `EventQueue` (production default `batchSize` 10). The chain
// enqueues BELOW that threshold — runExperience enqueues 1 bucketing entry (the sole 100%-traffic
// variation buckets EVERY visitor), the first trackConversion enqueues 2 conversion entries (the
// conversion event + the goalData-carrying transaction event), and the SECOND trackConversion is
// DEDUPED (same goal+visitor, `markGoalTriggeredIfNeeded` returns false ⇒ no new entry). All ~3 entries
// stay buffered (3 < 10, no size-flush Task fires), so the single manual `flush()` drains them into ONE
// `TrackingEvent` envelope ⇒ exactly ONE POST. That one envelope therefore carries the WHOLE chain —
// bucketing + conversion together — which is the FR27 end-to-end proof: the visitor's sticky bucketing
// decision rides onto the conversion event's `bucketingData`.
//
// ── No wall-clock waits (NFR21/NFR22) ─────────────────────────────────────────────────────────────
// Every cross-actor step is `await`ed; delivery is sequenced by the real `EventQueue.flush()`'s
// happens-before (it drains, uploads via the real uploader, and the await returns only once the
// stubbed POST has completed). No `Thread.sleep`, no `Task.sleep`, no poll.
//
// ── SonarQube 3% new-duplicated-lines gate ────────────────────────────────────────────────────────
// The SDK + real-EventQueue + stubbed-transport wiring is built ONCE in `makeFullChainSUT`; the
// GoalData payload is the single `Self.goalData` constant; the envelope read-back is the single
// `chainSummary(of:)` helper. No case re-inlines construction or the JSON walk.
//
// ── Isolation (bd-ilx) ────────────────────────────────────────────────────────────────────────────
// The production `DecisionStore` persists to a SHARED Application-Support file. To avoid cross-test
// leak the SUT injects a `DecisionStore` over an ephemeral `MockFileStore` AND uses a UNIQUE per-run
// `visitorId` (`"fc-visitor-<UUID>"`), so sticky keys never collide across runs. The EventQueue's store
// is a UUID-named temp `CoordinatedFileEventQueueStore`, removed in the test's `defer`.
import Testing
import Foundation
@testable import ConvertSDK

// MARK: - File-scope SUT + read-back carriers
//
// Declared at FILE SCOPE (not nested in the suite) on purpose: the suite is itself nested one level
// under the `URLProtocolStubBackedTests` parent (for the serialized-scope reasons in the header below),
// so a struct nested INSIDE the suite would be 2 levels deep and trip SwiftLint's `nesting` rule (max
// 1). File scope keeps them at level 0 — the same convention as `SchedulerSUT` in `TestFixtures.swift`.
// `private` so they stay invisible outside this file.

/// The fully-wired full-chain system under test plus the handles a test drives and asserts on. A named
/// struct (not a large tuple) satisfies the `large_tuple` rule and lets the test read members by name.
/// `Sendable` — `ConvertSDK` is `Sendable`, `EventQueue` is an `actor`, `URL`/`String` are value types.
private struct FullChainSUT: Sendable {
    /// The system under test — built ready, its `eventSink` the REAL `queue` below.
    let sdk: ConvertSDK
    /// The REAL `EventQueue` injected as the SDK's sink; the test `flush()`es it to drive the POST.
    let queue: EventQueue
    /// The UUID-named temp file backing the queue's `CoordinatedFileEventQueueStore` — removed by the
    /// test's `defer`.
    let queueStoreURL: URL
    /// The unique per-run visitor id the chain runs under (isolation — sticky keys never collide).
    let visitorId: String
}

/// What the test asserts about the POSTed envelope, recovered by encoding it back to a JSON tree
/// (`TrackingEventEntry`'s payload is `private`, so this is the only way to read the entry shapes — the
/// established walk from `TrackingEventCodableTests`). A named struct keeps the helper's return readable
/// and the `large_tuple` rule satisfied.
private struct ChainSummary {
    /// Every entry's `eventType` across all visitors, in wire order (expected ⊆ {bucketing, conversion}).
    let eventTypes: [String]
    /// `true` iff at least one CONVERSION entry carries a non-empty `data.bucketingData` map — the FR27
    /// end-to-end proof that the sticky bucketing decision rode onto the conversion event.
    let hasConversionWithBucketingData: Bool
}

// FR67 release-gate full-chain wiring suite, nested as a CHILD of the `URLProtocolStub-backed`
// `.serialized` parent (declared in `Adapters/URLSessionHTTPClientTests.swift`).
//
// ── Why nested under the shared parent (cross-suite reset race — verified) ─────────────────────────
// This suite drives the PROCESS-GLOBAL `URLProtocolStub`, whose per-URL count + captured-request
// registries are wiped WHOLESALE by any `reset()` (a global `removeAll()`). Keying the stub on a UNIQUE
// track URL prevents WRITE collisions but NOT a global `reset()`: when this suite ran as a SEPARATE
// top-level `.serialized` suite, a sibling case in `URLSessionHTTPClientTests`' parent (which runs in
// PARALLEL relative to an unrelated top-level suite — `.serialized` orders only WITHIN a tree) fired
// `reset()` between this suite's POST and its assertion, zeroing the count (observed: `recordedRequestCount
// → 0`, `recordedRequest → nil` in a full-suite run, while passing 3× in isolation). Nesting it here —
// exactly as `RecordedRequestCountTests` is — makes it inherit the parent's `isParallelizationEnabled =
// false` scope (the `ParallelizationTrait` installs that for the whole subtree via `Configuration.withCurrent`,
// regardless of which FILE a child suite is declared in — nesting is by TYPE containment, not file), so it
// runs serially RELATIVE TO the other stub-driving suites. Declared in THIS file (not moved into
// `URLSessionHTTPClientTests.swift`, already at 389 lines — moving it in would breach the 400-line
// `file_length` gate) via an `extension` of the parent enum, which is lexically a sub-suite all the same.
extension URLProtocolStubBackedTests {

/// `.serialized` (belt-and-suspenders atop the parent's scope) because it drives the process-global
/// `URLProtocolStub`, and resets it at suite construction AND teardown, mirroring
/// `URLSessionHTTPClientTests`'s reset discipline. A `final class` (not `struct`) so a `deinit` can run
/// the after-each reset — swift-testing builds a fresh suite instance per `@Test`, runs `init()` before
/// and `deinit` after.
@Suite("FullChainReleaseGate", .serialized)
final class FullChainIntegrationTests {

    // MARK: - Fixed chain identifiers (single owner each — SonarQube 3% gate)

    /// The experience key the chain buckets — its sole `traffic_allocation:100` variation covers the
    /// whole bucket space, so `runExperience` resolves it for EVERY visitor.
    private static let experienceKey = "exp-key"
    /// The goal key both `trackConversion` calls fire — present in the fixture, so it resolves.
    private static let goalKey = "purchase"
    /// The wire goal id the fixture's goal carries.
    private static let goalId = "goal-1"
    /// The SDK key — also the track-route scope segment, so the stubbed track URL embeds it.
    private static let sdkKey = "fc-key"
    /// The event-delivery base the REAL uploader POSTs under (no trailing slash). Deliberately distinct
    /// from any real CDN — the stub answers it, nothing reaches the network.
    private static let trackEndpoint = "https://track.test/api/v1"

    /// The GoalData the FIRST conversion carries — single owner of the literal so it is not re-inlined
    /// (SonarQube 3% gate). `.amount` + `.transactionId` is the canonical metric pair; the transaction
    /// event the first trigger emits carries these.
    private static let goalData: GoalData = [.amount: .double(9.99), .transactionId: .string("txn-001")]

    /// The exact URL the REAL `URLSessionEventUploader` POSTs to — `"{trackEndpoint}/track/{sdkKey}"`
    /// (verified in `URLSessionEventUploader.upload`). The stub is keyed on, and the request count
    /// asserted against, THIS url. A computed `URL?` (force-unwrap is banned — swiftlint `force_unwrapping`
    /// is opt-in/strict), unwrapped at the one use site via `#require`.
    private static let trackURL = URL(string: "\(trackEndpoint)/track/\(sdkKey)")

    // MARK: - Process-global stub reset discipline (NFR21)

    /// Resets the process-global `URLProtocolStub` before each test (fresh suite instance per `@Test`),
    /// so no registry entry or per-URL count leaks in from a prior case.
    init() {
        URLProtocolStub.reset()
    }

    /// Resets again after each test, so this suite never leaves global stub state behind for an unrelated
    /// suite (NFR21). Mirrors `URLSessionHTTPClientTests`'s symmetric before/after reset.
    deinit {
        URLProtocolStub.reset()
    }

    // MARK: - SUT

    /// Builds the full-chain SUT: a READY `ConvertSDK` whose config is supplied OUT-OF-BAND (the
    /// `configProvider` seam) and whose `eventSink` is a REAL `EventQueue` wired to a REAL
    /// `URLSessionEventUploader` over a REAL `URLSessionHTTPClient(session:)` with `URLProtocolStub`
    /// installed — so the track POST hits the stub. Single construction path (SonarQube 3% gate). The
    /// config is `makeExperienceAndGoalConfig` (one 100%-traffic experience EVERY visitor buckets into +
    /// one resolvable goal, under the SHARED `conversionFixtureAccountId`/`…ProjectId` = `acc1`/`p1`); the
    /// queue's `accountId`/`projectId` MUST match those ids so the envelope attribution is consistent, so
    /// they are read from the same shared constants the config uses.
    private func makeFullChainSUT() async throws -> FullChainSUT {
        // 1. Stubbed transport (mirrors `URLSessionHTTPClientTests.makeSUT`). `init()` already reset the
        //    stub; install it into a fresh ephemeral session so the uploader's POST is intercepted.
        let configuration = URLSessionConfiguration.ephemeral
        URLProtocolStub.install(into: configuration)
        let session = URLSession(configuration: configuration)
        let httpClient = URLSessionHTTPClient(session: session, sdkVersion: "9.9.9-test")

        // 2. REAL uploader → POSTs to `{trackEndpoint}/track/{sdkKey}` (the stubbed `Self.trackURL`).
        let uploader = URLSessionEventUploader(
            httpClient: httpClient,
            trackEndpoint: Self.trackEndpoint,
            sdkKey: Self.sdkKey
        )

        // 3. REAL EventQueue over a UUID-named temp store, attributed to the SAME ids as the config
        //    (acc1/p1) so the drained envelope's accountId/projectId match. The real uploader (NOT the
        //    T0 MockEventUploader) is the transport — that is the whole point of this chain test.
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let queue = EventQueue(
            accountId: conversionFixtureAccountId,
            projectId: conversionFixtureProjectId,
            uploader: uploader,
            eventBus: EventBus(),
            store: CoordinatedFileEventQueueStore(fileURL: storeURL, logger: NoopLogger())
        )

        // 4. Config: one 100%-traffic experience + one resolvable goal under acc1/p1.
        let config = try makeExperienceAndGoalConfig(
            experienceKey: Self.experienceKey,
            variationId: "var-1",
            variationKey: "var-key",
            goalKey: Self.goalKey,
            goalId: Self.goalId
        )

        // 5. SDK — config OUT-OF-BAND via `configProvider`; the REAL queue as `eventSink`; an ISOLATED
        //    DecisionStore over an ephemeral `MockFileStore` (no shared-file leak) + a UNIQUE visitorId.
        let visitorId = "fc-visitor-\(UUID().uuidString)"
        let sdk = ConvertSDK(
            configuration: ConvertConfiguration(sdkKey: Self.sdkKey),
            configProvider: MockConfigProvider.ungated(cached: nil, live: config),
            eventSink: queue,
            logger: NoopLogger(),
            decisionStore: DecisionStore(logger: NoopLogger(), fileStore: MockFileStore())
        )
        try await sdk.ready()
        return FullChainSUT(sdk: sdk, queue: queue, queueStoreURL: storeURL, visitorId: visitorId)
    }

    // MARK: - Envelope read-back (encoded — entry payload is private)

    /// Walks the decoded POST envelope into a ``ChainSummary``: collects every entry's `eventType` and
    /// detects a conversion entry whose `data.bucketingData` is a non-empty map. Records an `Issue` and
    /// returns an empty summary on a shape miss rather than force-unwrapping (no `!` — swiftlint
    /// `force_unwrapping`). Mirrors the `[[String: Any]]` JSON-tree walk in `TrackingEventCodableTests`.
    private static func chainSummary(of envelope: TrackingEvent) -> ChainSummary {
        guard let root = try? JSONEncoder().encode(envelope),
              let tree = try? JSONSerialization.jsonObject(with: root) as? [String: Any],
              let visitors = tree["visitors"] as? [[String: Any]] else {
            Issue.record("POST envelope did not encode to the expected visitors[] JSON shape")
            return ChainSummary(eventTypes: [], hasConversionWithBucketingData: false)
        }
        var eventTypes: [String] = []
        var hasConversionWithBucketingData = false
        for visitor in visitors {
            let events = visitor["events"] as? [[String: Any]] ?? []
            for event in events {
                let eventType = event["eventType"] as? String ?? ""
                eventTypes.append(eventType)
                let data = event["data"] as? [String: Any]
                let bucketingData = data?["bucketingData"] as? [String: String] ?? [:]
                if eventType == "conversion" && !bucketingData.isEmpty {
                    hasConversionWithBucketingData = true
                }
            }
        }
        return ChainSummary(eventTypes: eventTypes, hasConversionWithBucketingData: hasConversionWithBucketingData)
    }

    // MARK: - POST body recovery (httpBodyStream, not httpBody)

    /// The body bytes of a POST request captured by ``URLProtocolStub``. `URLSession` hands a
    /// body-carrying request to the intercepting `URLProtocol` with its body as `httpBodyStream` and
    /// `httpBody == nil` (verified empirically on the project toolchain — a long-standing `URLProtocol`
    /// contract, NOT a stub bug: the stored request still carries the body, just as a stream). The stub's
    /// `startLoading` never consumes that stream, so it is unopened and fully readable here. Drains it in
    /// bounded 4 KiB reads; returns `nil` (so the caller's `#require` reports it) when there is no stream.
    /// No force-unwrap (swiftlint `force_unwrapping`).
    private static func bodyBytes(of request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return request.httpBody }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: - FR67 full-chain release gate

    /// The release-gate wiring test: drive the REAL public SDK API through the full chain and assert the
    /// produced events land as ONE canonical POST envelope on the track URL, with the dedup'd second
    /// conversion adding NO extra POST and the conversion entry carrying the visitor's bucketingData
    /// (FR27 end-to-end). Steps are extracted into helpers so this body stays under the 50-line rule.
    @Test("the full public chain produces exactly one canonical POST carrying bucketing + conversion")
    func fullChainProducesOneCanonicalPost() async throws {
        let sut = try await makeFullChainSUT()
        defer { try? FileManager.default.removeItem(at: sut.queueStoreURL) }

        // The REAL uploader POSTs to this URL; stub a 200 so the chain completes (config GET is served by
        // the configProvider, NOT the stub — only the track POST is stubbed).
        let trackURL = try #require(Self.trackURL, "the track URL must construct")
        URLProtocolStub.stub(url: trackURL, statusCode: 200, data: Data("{}".utf8), headers: [:])

        try await driveChain(sut)

        // Flush the REAL queue: drains the buffered batch (1 bucketing + 2 conversion) and POSTs it as ONE
        // envelope via the real uploader → stubbed trackURL. The await returns only once the POST settled
        // (happens-before — no wall-clock wait).
        await sut.queue.flush()

        // (1) Exactly ONE POST — the whole batch is one envelope, and the dedup'd second conversion added
        //     nothing.
        #expect(
            URLProtocolStub.recordedRequestCount(for: trackURL) == 1,
            "exactly one POST /track — the batch is one envelope and dedup suppressed the second conversion"
        )

        // (2) Canonical envelope: decode the POST body and assert the hardcoded wire invariants + chain.
        let request = try #require(URLProtocolStub.recordedRequest(for: trackURL), "the POST must be captured")
        // `httpBody` is nil on a URLProtocol-intercepted POST — the body arrives as `httpBodyStream`
        // (see `bodyBytes(of:)`); drain that to recover the wire bytes.
        let body = try #require(Self.bodyBytes(of: request), "the POST must carry a body")
        let envelope = try JSONDecoder().decode(TrackingEvent.self, from: body)
        #expect(envelope.enrichData == false, "enrichData is hardcoded false")
        #expect(envelope.source == "ios-sdk", "source is hardcoded ios-sdk")
        #expect(envelope.accountId == conversionFixtureAccountId, "envelope attribution is the config's account")

        // (3) The WHOLE chain rode in this one envelope, with the dedup boundary visible in the counts:
        //     every entry is bucketing|conversion; the single runExperience bucketing entry is present;
        //     EXACTLY two conversion entries arrived (the first trigger's conversion + transaction events,
        //     and ZERO from the deduped second trackConversion); and a conversion carries the visitor's
        //     sticky bucketingData (FR27 end-to-end).
        let summary = Self.chainSummary(of: envelope)
        #expect(
            Set(summary.eventTypes).isSubset(of: ["bucketing", "conversion"]),
            "every delivered entry is a bucketing or conversion event"
        )
        #expect(
            summary.eventTypes.filter { $0 == "bucketing" }.count == 1,
            "the single runExperience bucketing entry rode the chain"
        )
        #expect(
            summary.eventTypes.filter { $0 == "conversion" }.count == 2,
            "exactly two conversion entries — the first trigger's pair; the dedup'd second added none"
        )
        #expect(
            summary.hasConversionWithBucketingData,
            "a conversion event carries the visitor's sticky bucketingData (FR27 end-to-end)"
        )

        // TODO(pre-release): R3 — verify deployed node-server-metrics-ts honors ConvertAgent/ UA bypass
    }

    /// Drives the REAL public chain on `sut`: createContext → runExperience (buckets the sole
    /// 100%-traffic variation) → runFeature (exercised; the fixture has no feature, so a disabled miss is
    /// expected and must not crash) → setDefaultSegments → trackConversion WITH goalData (first trigger) →
    /// trackConversion again (same goal+visitor ⇒ DEDUP, no new event). Extracted from the test body so
    /// that body stays under the 50-line rule and the drive sequence has one owner.
    private func driveChain(_ sut: FullChainSUT) async throws {
        let context = sut.sdk.createContext(visitorId: sut.visitorId)

        let variation = await context.runExperience(Self.experienceKey)
        #expect(variation != nil, "the sole 100%-traffic variation must bucket every visitor")

        // runFeature returns a Feature (disabled on a miss); the fixture carries no feature, so
        // this just exercises the path — it must return a value, not crash.
        let feature = await context.runFeature("fc-missing-feature")
        #expect(feature.status == .disabled, "a missing feature resolves to a disabled Feature")

        await context.setDefaultSegments(["country": "US"])

        // FIRST conversion WITH goalData → enqueues the conversion event + the transaction event.
        await context.trackConversion(Self.goalKey, goalData: Self.goalData)
        // SECOND conversion, same goal + visitor, no goalData → DEDUPED (no new event enqueued).
        await context.trackConversion(Self.goalKey)
    }
}

} // extension URLProtocolStubBackedTests
