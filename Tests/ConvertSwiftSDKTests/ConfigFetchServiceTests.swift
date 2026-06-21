// Tests/ConvertSwiftSDKTests/ConfigFetchServiceTests.swift
//
// RED phase (Epic 2, Story 3 — config-fetch coordinator): this suite exercises
// `ConfigFetchService`, the `Sendable` coordinator that builds the config URL,
// fetches the live config (write-through caching the RAW response bytes), and
// loads / repairs the on-disk cache. The type DOES NOT EXIST YET — the GREEN step
// creates it at `Sources/ConvertSwiftSDK/ConfigFetchService.swift`. Until then this file
// fails to compile with "cannot find 'ConfigFetchService' in scope", which is the
// expected RED state for this TDD cycle. (Every collaborator referenced here —
// `MockHTTPClient`, `MockLogger`, `LockedBox` from `MockPorts.swift`,
// `CoordinatedFileStore`, `ConvertConfiguration`, `CacheLevel`, `ProjectConfig`,
// `LogLevel` — already compiles; only the `ConfigFetchService` references are
// unresolved.)
//
// ── ASSUMED GREEN INIT SEAM (load-bearing — the implementer MUST match this) ───
// The service takes the cache URL via init so tests inject a UNIQUE TEMP URL and
// never touch the real Application Support directory (where
// `CoordinatedFileStore.configCacheURL(for:)` points). In production the `cacheURL`
// argument DEFAULTS to that real path; tests override it. Assumed signature:
//
//   init(
//       httpClient: any HTTPClient,
//       fileStore: CoordinatedFileStore,
//       configuration: ConvertConfiguration,
//       logger: any Logger,
//       cacheURL: URL = CoordinatedFileStore.configCacheURL(for: configuration.sdkKey)
//   )
//
// (A Swift default-argument expression cannot reference an earlier parameter, so the
// GREEN implementer either provides this via a convenience overload / factory or a
// nil-sentinel that resolves to `configCacheURL(for: configuration.sdkKey)` inside
// the body. What the TESTS require is only that `cacheURL:` is injectable; the
// production default path is the implementer's to wire. The seam is the contract.)
//
// Public API driven by these tests:
//   * `func buildConfigURL() throws -> URL`
//   * `func loadCachedConfig() async -> ProjectConfig?`
//   * `func fetchLiveConfig() async -> ProjectConfig?`
// The service returns optionals and does NOT touch ConfigStore.
//
// ── Transport double: MockHTTPClient (NOT URLProtocolStub) ────────────────────
// These tests use the `MockHTTPClient` ACTOR from `MockPorts.swift`, never
// `URLProtocolStub`. Rationale: (1) `MockHTTPClient(response: (data, httpResponse))`
// lets a test set the EXACT response `Data` byte-for-byte — required for the raw-byte
// write-through assertion (`fetchLiveConfigWritesRawBytesToCache`), which proves the
// service caches the verbatim bytes from `get()` rather than re-encoding the decoded
// config (a re-encode would reorder keys and the byte-equality would fail). (2)
// `MockHTTPClient` holds NO process-global state — each test gets its own instance —
// so this suite is parallel-safe and needs NO nesting under the `.serialized`
// `URLProtocolStubBackedTests` parent: URLProtocolStub's global `reset()` race
// (documented in `URLSessionHTTPClientTests.swift`) is structurally impossible here.
// `MockHTTPClient.requests` records each request's headers for the auth assertions.
//
// ── Isolation + cleanup shape (NFR21 — no test artifacts leak) ────────────────
// Every cache URL is a UNIQUE path under `FileManager.default.temporaryDirectory`
// (a fresh UUID subdirectory) so cases never collide and never touch the real
// Application Support dir. Each UUID dir is recorded and removed in `deinit`
// (swift-testing makes a fresh suite instance per `@Test` and runs `deinit` after
// it). A `final class` (not `struct`) carries the `deinit`; the recorded-dirs set is
// held in a `LockedBox` (the lock-cell from `MockPorts.swift`) so the mutable
// instance state is `Sendable`-safe on this package's macOS 12 / iOS 15 floor (where
// `Synchronization.Mutex` is unavailable) and reads soundly from `deinit` — mirroring
// `CoordinatedFileStoreTests`.

import Testing
import Foundation
@testable import ConvertSwiftSDK

@Suite("ConfigFetchService")
final class ConfigFetchServiceTests {
    // MARK: - Shared constants

    /// SDK key used across the suite. Also the cache-file key the production default
    /// path would derive from, but tests always inject an explicit temp `cacheURL`.
    static let sdkKey = "sk_test_abc"
    /// The default config base (no trailing slash) — `ConvertConfiguration.defaultAPIBase`.
    /// Used to assemble the expected URL string the builder must produce.
    static let defaultBase = "https://cdn-4.convertexperiments.com/api/v1"
    /// A valid, minimal config JSON whose `account_id` the decode tests assert on.
    /// Constructed locally (NOT the ConvertSwiftSDKCoreTests baseline fixture — wrong target).
    static let validConfigJSON = Data(#"{"account_id":"acc-1","project":{"id":"p-1"}}"#.utf8)
    /// The `accountId` carried by ``validConfigJSON`` — the decode assertions compare to this.
    static let validAccountId = "acc-1"

    // MARK: - Cleanup bookkeeping

    /// Temp directories created by ``uniqueCacheURL()``, removed in ``deinit`` so no
    /// test artifact survives the run (NFR21). Held in a ``LockedBox`` (defined in
    /// `MockPorts.swift`) so this mutable instance state is `Sendable`-safe and can be
    /// read back during teardown.
    private let createdDirs = LockedBox<[URL]>([])

    /// Removes every temp directory this suite created. Runs after each `@Test`
    /// (fresh suite instance per case), so no scratch dir leaks into the next case or
    /// an unrelated suite.
    deinit {
        let manager = FileManager.default
        for dir in createdDirs.get {
            try? manager.removeItem(at: dir)
        }
    }

    // MARK: - Factories / helpers (SonarQube new-code duplication discipline)

    /// Builds a UNIQUE cache-file URL under a fresh UUID temp subdirectory and records
    /// that subdirectory for ``deinit`` cleanup. Unique per call so cases never collide
    /// and never touch the real Application Support dir. Centralizing it here keeps the
    /// temp-URL construction from being copy-pasted across tests.
    private func uniqueCacheURL(filename: String = "config-cache.json") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        createdDirs.withLock { $0.append(dir) }
        return dir.appendingPathComponent(filename)
    }

    /// Builds a 200 `HTTPURLResponse` for `url`. Shared so no fetch test reconstructs
    /// the response inline (the response object is incidental to the byte-level
    /// assertions, which care only about the body `Data`).
    private func okResponse(for url: URL) -> HTTPURLResponse {
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

    /// Everything a test needs to drive and inspect a ``ConfigFetchService``: the
    /// service under test, the transport double (to read recorded request headers),
    /// the file store + the temp `cacheURL` (to inspect on-disk bytes), and the logger
    /// (to assert emitted WARNs). A named struct (not a tuple) keeps the `large_tuple`
    /// lint rule satisfied and lets tests read handles by name.
    private struct SUT {
        let service: ConfigFetchService
        let httpClient: MockHTTPClient
        let fileStore: CoordinatedFileStore
        let cacheURL: URL
        let logger: MockLogger
    }

    /// Single wiring point for every test: assembles a `ConvertConfiguration`, a
    /// `MockHTTPClient` (canned response and/or error), a real `CoordinatedFileStore`,
    /// a unique temp `cacheURL`, and a `MockLogger`, then constructs the service via
    /// the injected-`cacheURL` seam. No test copies this wiring or the write/read
    /// blocks (SonarQube 3% new-code-duplication gate).
    ///
    /// - Parameters:
    ///   - sdkKey: project key for the configuration (default ``sdkKey``).
    ///   - secret: optional `sdkKeySecret` — drives the Authorization-header tests.
    ///   - environment: optional environment selector — drives the URL-builder query.
    ///   - cacheLevel: `.normal` or `.low` — drives the `_conv_low_cache=1` query.
    ///   - cacheURL: the on-disk cache path the service reads/writes; ALWAYS a unique
    ///     temp URL here so the suite never touches Application Support.
    ///   - httpResponse: canned body `Data` for `get()`; paired with a 200 response.
    ///     Pass the EXACT bytes when a test asserts on the cached payload.
    ///   - httpError: canned `URLError` thrown by `get()`; takes precedence over a
    ///     configured response (matches `MockHTTPClient` semantics).
    private func makeSUT(
        sdkKey: String = ConfigFetchServiceTests.sdkKey,
        secret: String? = nil,
        environment: String? = nil,
        cacheLevel: CacheLevel = .normal,
        cacheURL: URL? = nil,
        httpResponse: Data? = nil,
        httpError: URLError? = nil
    ) -> SUT {
        let resolvedCacheURL = cacheURL ?? uniqueCacheURL()
        let configuration = ConvertConfiguration(
            sdkKey: sdkKey,
            sdkKeySecret: secret,
            environment: environment,
            networkCacheLevel: cacheLevel
        )
        let cannedResponse = httpResponse.map { ($0, okResponse(for: resolvedCacheURL)) }
        let httpClient = MockHTTPClient(response: cannedResponse, error: httpError)
        let fileStore = CoordinatedFileStore()
        let logger = MockLogger()
        let service = ConfigFetchService(
            httpClient: httpClient,
            fileStore: fileStore,
            configuration: configuration,
            logger: logger,
            cacheURL: resolvedCacheURL
        )
        return SUT(
            service: service,
            httpClient: httpClient,
            fileStore: fileStore,
            cacheURL: resolvedCacheURL,
            logger: logger
        )
    }

    /// Reads the Authorization header off the single request the transport recorded,
    /// returning `nil` when no Authorization header was sent. Fails the test (rather
    /// than passing silently) if NO request was recorded at all — proving the service
    /// actually issued the fetch. Shared by the two auth-header assertions so neither
    /// repeats the unwrap.
    private func recordedAuthorization(
        _ httpClient: MockHTTPClient,
        _ sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> String? {
        let requests = await httpClient.requests
        let request = try #require(
            requests.first,
            "the service issued no request to the transport",
            sourceLocation: sourceLocation
        )
        return request.headers["Authorization"]
    }

    // MARK: - URL builder

    /// `buildConfigURL()` assembles `{base}/config/{sdkKey}` and appends
    /// `environment={value}` (when set) and `_conv_low_cache=1` (when cacheLevel ==
    /// .low). Parameterized over the four env × cacheLevel combinations so the
    /// build-and-inspect logic lives once (SonarQube new-code-duplication discipline)
    /// instead of four near-identical test bodies. Assertions go through
    /// `URLComponents` on the BUILT URL (path suffix + the query-item set), not raw
    /// string compare, so query-item ordering is not over-specified.
    @Test(
        "buildConfigURL appends environment and low-cache query items per configuration",
        arguments: [
            (environment: String?.none, cacheLevel: CacheLevel.normal, expectedQuery: [String: String]()),
            (environment: "production", cacheLevel: .normal, expectedQuery: ["environment": "production"]),
            (environment: String?.none, cacheLevel: .low, expectedQuery: ["_conv_low_cache": "1"]),
            (
                environment: "production",
                cacheLevel: .low,
                expectedQuery: ["environment": "production", "_conv_low_cache": "1"]
            )
        ]
    )
    func buildConfigURLAppendsQueryItems(
        environment: String?,
        cacheLevel: CacheLevel,
        expectedQuery: [String: String]
    ) throws {
        let sut = makeSUT(environment: environment, cacheLevel: cacheLevel)

        let url = try sut.service.buildConfigURL()

        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false),
            "built URL is not decomposable into URLComponents"
        )
        // Path must end with /config/{sdkKey} regardless of query.
        #expect(url.path.hasSuffix("/config/\(Self.sdkKey)"))
        // The query-item SET must equal the expected name→value map (order-agnostic).
        let queryItems = components.queryItems ?? []
        let pairs: [(String, String)] = queryItems.map { item in (item.name, item.value ?? "") }
        let actualQuery = Dictionary(uniqueKeysWithValues: pairs)
        #expect(actualQuery == expectedQuery)
        // No-query case: there must be NO "?" segment at all.
        if expectedQuery.isEmpty {
            #expect(components.queryItems == nil || components.queryItems?.isEmpty == true)
            #expect(url.absoluteString == "\(Self.defaultBase)/config/\(Self.sdkKey)")
        }
    }

    // MARK: - Authorization header

    /// When `sdkKeySecret` is set, `fetchLiveConfig()` sends `Authorization:
    /// Bearer {secret}` on the GET. Driven through `MockHTTPClient`, which records the
    /// outbound request headers.
    @Test("fetchLiveConfig sends a Bearer Authorization header when a secret is configured")
    func appendsBearerWhenSecretPresent() async throws {
        let secret = "super-secret-token"
        let sut = makeSUT(secret: secret, httpResponse: Self.validConfigJSON)

        _ = await sut.service.fetchLiveConfig()

        let authorization = try await recordedAuthorization(sut.httpClient)
        #expect(authorization == "Bearer \(secret)")
    }

    /// When no `sdkKeySecret` is configured, `fetchLiveConfig()` sends NO Authorization
    /// header — the recorded request carries no such field.
    @Test("fetchLiveConfig sends no Authorization header when no secret is configured")
    func noAuthWhenNoSecret() async throws {
        let sut = makeSUT(secret: nil, httpResponse: Self.validConfigJSON)

        _ = await sut.service.fetchLiveConfig()

        let authorization = try await recordedAuthorization(sut.httpClient)
        #expect(authorization == nil)
    }

    // MARK: - fetchLiveConfig: decode / failure / write-through

    /// On a 200 with a valid config body, `fetchLiveConfig()` returns a non-nil
    /// `ProjectConfig` decoded from the response, carrying the expected `accountId`.
    @Test("fetchLiveConfig decodes a valid 200 response into a ProjectConfig")
    func fetchLiveConfigDecodesValidResponse() async throws {
        let sut = makeSUT(httpResponse: Self.validConfigJSON)

        let config = await sut.service.fetchLiveConfig()

        let decoded = try #require(config, "a valid 200 body must decode to a non-nil config")
        #expect(decoded.accountId == Self.validAccountId)
    }

    /// On a transport failure (the `MockHTTPClient` throws a `URLError`),
    /// `fetchLiveConfig()` returns `nil` and does NOT propagate the error to the
    /// caller — the coordinator swallows network errors into a cache-miss `nil`.
    @Test("fetchLiveConfig returns nil (does not throw) on a network failure")
    func fetchLiveConfigNetworkFailureReturnsNil() async {
        let sut = makeSUT(httpError: URLError(.notConnectedToInternet))

        let config = await sut.service.fetchLiveConfig()

        #expect(config == nil)
    }

    /// THE inherited-contract write-through assertion (#4 — the most important test in
    /// this suite). On a successful fetch, the service writes the RAW response bytes —
    /// the verbatim `Data` returned by `get()` — to the cache, NOT a re-encode of the
    /// decoded config. The test feeds an EXACT known JSON payload, then reads the cache
    /// file back through the SAME `CoordinatedFileStore` (at the injected temp
    /// `cacheURL`) and asserts byte-for-byte equality. A re-encode would reorder keys
    /// and fail this equality, which is precisely what this test exists to catch.
    @Test("fetchLiveConfig writes the verbatim response bytes to the cache (no re-encode)")
    func fetchLiveConfigWritesRawBytesToCache() async throws {
        // A payload whose key order is deliberately NOT what a fresh JSONEncoder would
        // emit, so a re-encode would produce different bytes and fail the equality.
        let exactBytes = Data(#"{"project":{"id":"p-9"},"account_id":"acc-9"}"#.utf8)
        let sut = makeSUT(httpResponse: exactBytes)

        let config = await sut.service.fetchLiveConfig()

        // Sanity: the fetch succeeded (so a write was expected to happen).
        #expect(config != nil)
        // The on-disk cache bytes must EQUAL the exact response bytes, byte-for-byte.
        let onDisk = try await sut.fileStore.read(from: sut.cacheURL)
        #expect(onDisk == exactBytes)
    }

    // MARK: - loadCachedConfig: present / corrupt / missing

    /// With a valid config JSON pre-written to the cache path, `loadCachedConfig()`
    /// reads + decodes it and returns the `ProjectConfig` (with the expected
    /// `accountId`). The pre-write goes through the SAME `CoordinatedFileStore` the
    /// service reads from, exercising the real on-disk round trip.
    @Test("loadCachedConfig returns the decoded config when a valid cache file is present")
    func loadCachedConfigReturnsConfigWhenCachePresent() async throws {
        let sut = makeSUT()
        try await sut.fileStore.write(Self.validConfigJSON, to: sut.cacheURL)

        let config = await sut.service.loadCachedConfig()

        let decoded = try #require(config, "a valid cache file must decode to a non-nil config")
        #expect(decoded.accountId == Self.validAccountId)
    }

    /// AC4 — corrupt-cache repair. With non-JSON bytes pre-written to the cache path,
    /// `loadCachedConfig()` (1) returns `nil`, (2) emits a WARN through the logger, and
    /// (3) DELETES the corrupt file so a subsequent read fails (the file is absent).
    /// The WARN is asserted via `MockLogger.entries` filtered to `level == .warn`; the
    /// deletion via a follow-up `read` that must throw.
    ///
    /// NOTE on the degrading decoder: `ProjectConfig.init(from:)` degrades per FIELD
    /// but still requires the TOP-LEVEL bytes to be valid JSON (it opens a keyed
    /// container first). `"not-json"` is not valid JSON, so the decode throws at the
    /// container boundary — which is the corruption path this test drives. (A
    /// well-formed-but-drifted body would decode degraded, NOT corrupt; that is a
    /// different contract, not exercised here.)
    @Test("loadCachedConfig on corrupt bytes returns nil, logs a WARN, and deletes the cache")
    func loadCachedConfigCorruptBytesLogsWarnDeletesReturnsNil() async throws {
        let sut = makeSUT()
        let corruptBytes = Data("not-json".utf8)
        try await sut.fileStore.write(corruptBytes, to: sut.cacheURL)

        let config = await sut.service.loadCachedConfig()

        // (1) returns nil
        #expect(config == nil)
        // (2) a WARN was logged for the corrupt cache
        let warnings = sut.logger.entries().filter { $0.level == .warn }
        #expect(!warnings.isEmpty)
        // (3) the corrupt file was deleted — a follow-up read must now throw (absent).
        await #expect(throws: (any Error).self) {
            _ = try await sut.fileStore.read(from: sut.cacheURL)
        }
    }

    /// With NO cache file present, `loadCachedConfig()` returns `nil` and does NOT
    /// throw — a missing cache is an ordinary miss, not an error surfaced to the caller.
    @Test("loadCachedConfig returns nil (does not throw) when no cache file exists")
    func loadCachedConfigMissingReturnsNil() async {
        let sut = makeSUT()

        let config = await sut.service.loadCachedConfig()

        #expect(config == nil)
    }
}
