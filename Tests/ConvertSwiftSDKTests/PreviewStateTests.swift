// Tests/ConvertSwiftSDKTests/PreviewStateTests.swift
//
// RED phase (qs-02 IOS-4, AC8 — preview memoization). Pins `PreviewState`: an `actor`, living in
// the `ConvertSwiftSDK` platform target (it holds a concrete `ConfigFetchService`, which composes
// Foundation-only ports — mirrors `TrackingState`'s placement rationale), that memoizes
// `ConfigFetchService.fetchExperienceConfig(experienceId:)` results IN-MEMORY ONLY (never the
// on-disk config cache), keyed per `experienceId`, with a 60s TTL driven by an INJECTABLE
// `Clock` (the SAME `Clock` port `ConfigRefreshScheduler` already uses — this reuses the
// existing `MockClock` test double; no new clock abstraction is introduced). Expired entries are
// swept on EVERY access (both the read path — a memo hit/miss check — and the write path — after
// a fresh fetch is inserted), bounding growth without a separate timer.
//
// `PreviewState` is deliberately NOT single-purpose to the memo: it is the actor a later story
// (qs-02 IOS-5) will ALSO use to hold the per-context current `(experienceId, variationId)`
// preview target (mirroring `TrackingState`'s "one actor, held by `let`, on the owning type"
// shape) — this file exercises only the memo surface these tests need; IOS-5 adds to the SAME
// type rather than introducing a second one.
//
// ── Integration-seam decision this file pins (qs-02 IOS-4) ────────────────────────────────────
// `PreviewState` is constructed over a CONCRETE `ConfigFetchService` value (not a protocol or a
// closure): `ConfigFetchService` is already a cheap `Sendable` struct (`ConfigFetchService.swift`
// lines ~34-70), so no new seam type is needed for a single-consumer dependency. A later story
// (IOS-5) will have `ConvertContext` hold a `PreviewState` built by `ConvertSwiftSDK.createContext`
// over a second `ConfigFetchService` instance constructed there (the composition-root local built
// inside the config-load `Task`, `ConvertSwiftSDK.swift` lines ~319-324, is not stored anywhere a
// context could reach — `ConvertContext` does not own a `ConfigFetchService` today).
//
// This file fails to compile until `PreviewState` and
// `ConfigFetchService.fetchExperienceConfig(experienceId:)` exist (GREEN, qs-02 IOS-4).
//
// ── Transport double: MockHTTPClient (NOT URLProtocolStub) ────────────────────────────────────
// Mirrors `ConfigFetchServiceTests.swift`'s house style: ONE canned response is reused across
// every `experienceId` in a case — these tests assert FETCH COUNTS (via `MockHTTPClient.requests`,
// filtered by the request URL's `exp=` query value), never per-id response-body differentiation,
// so a single canned response is sufficient and keeps the suite parallel-safe (no process-global
// `URLProtocolStub` registry, no `.serialized` nesting needed).
import Testing
import Foundation
@testable import ConvertSwiftSDK

@Suite("PreviewState")
final class PreviewStateTests {
    /// Temp directories created by ``uniqueCacheURL()``, removed in ``deinit`` so no test
    /// artifact survives the run (NFR21) — mirrors `ConfigFetchServiceTests`'s cleanup discipline.
    private let createdDirs = LockedBox<[URL]>([])

    deinit {
        let manager = FileManager.default
        for dir in createdDirs.get {
            try? manager.removeItem(at: dir)
        }
    }

    // MARK: - Factories / helpers (SonarQube new-code duplication discipline)

    /// Builds a UNIQUE cache-file URL under a fresh UUID temp subdirectory and records that
    /// subdirectory for ``deinit`` cleanup — the exp path must never touch this file, so every
    /// test that asserts "disk cache untouched" reads back from exactly this path.
    private func uniqueCacheURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        createdDirs.withLock { $0.append(dir) }
        return dir.appendingPathComponent("config-cache.json")
    }

    /// Builds a 200 `HTTPURLResponse`. The `url` is incidental (`ConfigFetchService` never
    /// inspects the response object, only the paired `Data`), so the temp `cacheURL` itself is
    /// reused rather than constructing a second URL literal.
    private func stubResponse(for url: URL) -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            preconditionFailure("HTTPURLResponse(statusCode:200) is non-failing for a valid URL")
        }
        return response
    }

    /// Everything a test needs to drive and inspect a ``PreviewState``: the actor under test,
    /// the transport double (to count/filter requests by `exp=` value), the file store + temp
    /// `cacheURL` (to prove the on-disk config cache is never touched), and the injectable
    /// ``MockClock`` (to advance time synthetically per NFR21 — no wall-clock waits).
    private struct SUT {
        let previewState: PreviewState
        let httpClient: MockHTTPClient
        let fileStore: CoordinatedFileStore
        let cacheURL: URL
        let clock: MockClock
    }

    /// Single wiring point for every test in this suite: a `ConvertConfiguration`, a
    /// `MockHTTPClient` canning ONE valid config response (reused across every `experienceId`
    /// a test drives), a real `CoordinatedFileStore` at a unique temp `cacheURL`, and a
    /// `MockClock` seeded at `now` (defaulting to the Unix epoch so `addingTimeInterval` math in
    /// the tests reads as plain elapsed seconds).
    private func makeSUT(now: Date = Date(timeIntervalSince1970: 0)) -> SUT {
        let cacheURL = uniqueCacheURL()
        let configuration = ConvertConfiguration(sdkKey: "sk_preview_state")
        let response = (ConfigFetchServiceTests.validConfigJSON, stubResponse(for: cacheURL))
        let httpClient = MockHTTPClient(response: response)
        let fileStore = CoordinatedFileStore()
        let fetchService = ConfigFetchService(
            httpClient: httpClient,
            fileStore: fileStore,
            configuration: configuration,
            logger: MockLogger(),
            cacheURL: cacheURL
        )
        let clock = MockClock(now: now)
        let previewState = PreviewState(fetchService: fetchService, clock: clock)
        return SUT(
            previewState: previewState,
            httpClient: httpClient,
            fileStore: fileStore,
            cacheURL: cacheURL,
            clock: clock
        )
    }

    /// Counts `requests` whose URL carries `exp={experienceId}` — shared by every test that
    /// asserts a fetch count, so the `URLComponents` filter logic lives once (SonarQube
    /// new-code-duplication discipline).
    private func fetchCount(for experienceId: String, in requests: [MockHTTPClient.Request]) -> Int {
        requests.filter { request in
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "exp" && $0.value == experienceId } ?? false
        }.count
    }

    // MARK: - AC8: 60s memoization + expiry

    /// `resolveConfig(experienceId:)` for the SAME id: a second resolution issued BEFORE the
    /// injected clock crosses the 60s TTL reuses the memoized config (exactly ONE fetch total);
    /// a second resolution issued AFTER the clock crosses 60s treats the memo as expired and
    /// issues a NEW fetch (two fetches total). Parameterized over the two clock-advance amounts
    /// so the resolve-twice-and-count logic lives once (SonarQube new-code-duplication
    /// discipline) instead of two near-identical bodies. Every case ALSO asserts the on-disk
    /// config cache is never touched by the exp path, memoized or not.
    @Test(
        "resolveConfig memoizes within the 60s TTL and treats the memo as expired past it",
        arguments: [
            (advanceSeconds: 30.0, expectedFetchCount: 1),
            (advanceSeconds: 61.0, expectedFetchCount: 2)
        ]
    )
    func resolveConfigMemoizesWithinTTLAndExpiresAfter(
        advanceSeconds: Double,
        expectedFetchCount: Int
    ) async throws {
        let sut = makeSUT()
        let experienceId = "123"

        let first = await sut.previewState.resolveConfig(experienceId: experienceId)
        sut.clock.setNow(Date(timeIntervalSince1970: 0).addingTimeInterval(advanceSeconds))
        let second = await sut.previewState.resolveConfig(experienceId: experienceId)

        #expect(first != nil)
        #expect(second != nil)
        let requests = await sut.httpClient.requests
        #expect(fetchCount(for: experienceId, in: requests) == expectedFetchCount)
        // The exp path never writes to the on-disk config cache — memoized or freshly fetched.
        await #expect(throws: (any Error).self) {
            _ = try await sut.fileStore.read(from: sut.cacheURL)
        }
    }

    // MARK: - Per-experienceId independence

    /// Two DIFFERENT `experienceId`s are memoized independently: resolving `"A"` does not
    /// consult or consume the memo entry for `"B"`, and a repeat resolution of either (still
    /// within the TTL) reuses ITS OWN memoized entry rather than triggering a fetch for the
    /// other id.
    @Test("resolveConfig memoizes each experienceId independently")
    func resolveConfigMemoizesEachExperienceIdIndependently() async throws {
        let sut = makeSUT()

        _ = await sut.previewState.resolveConfig(experienceId: "A")
        _ = await sut.previewState.resolveConfig(experienceId: "B")
        _ = await sut.previewState.resolveConfig(experienceId: "A")
        _ = await sut.previewState.resolveConfig(experienceId: "B")

        let requests = await sut.httpClient.requests
        #expect(fetchCount(for: "A", in: requests) == 1)
        #expect(fetchCount(for: "B", in: requests) == 1)
    }

    // MARK: - Expired-entry sweep

    /// Accessing the memo after an entry has expired SWEEPS (removes) it, bounding growth —
    /// asserted via the internal `memoCount` introspection: after resolving `"A"` the memo holds
    /// exactly one entry; once the clock advances past the 60s TTL, resolving a DIFFERENT id
    /// `"B"` sweeps `"A"`'s now-expired entry on that same access, so the memo again holds
    /// exactly one entry (only `"B"`'s fresh one) rather than accumulating both.
    @Test("resolveConfig sweeps expired memo entries on access, bounding growth")
    func resolveConfigSweepsExpiredEntriesOnAccess() async throws {
        let sut = makeSUT()

        _ = await sut.previewState.resolveConfig(experienceId: "A")
        let countAfterA = await sut.previewState.memoCount
        #expect(countAfterA == 1)

        sut.clock.setNow(Date(timeIntervalSince1970: 0).addingTimeInterval(61))
        _ = await sut.previewState.resolveConfig(experienceId: "B")
        let countAfterSweep = await sut.previewState.memoCount

        #expect(countAfterSweep == 1)
    }
}
