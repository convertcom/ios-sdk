// Tests/ConvertSwiftSDKTests/DebugTokenRedactionTests.swift
//
// RED phase (qs-02 IOS-1, AC3 — token hygiene): proves the CRITICAL VERIFIED DIVERGENCE that
// `ConfigFetchService`'s network-failure WARN line (`fetchLiveConfig`'s catch around the
// `httpClient.get(...)` call, `Sources/ConvertSwiftSDK/ConfigFetchService.swift` lines ~210-217)
// currently LEAKS a `debugToken` value in clear. `String(describing: error)` on a genuine
// `URLSession` transport failure embeds the failing URL — Foundation's URL Loading System
// attaches `NSErrorFailingURLStringKey` / `NSURLErrorFailingURLStringErrorKey` to any surfaced
// `URLError` automatically, regardless of what failed the load — so when the URL carries
// `debug_token=<value>`, that value rides straight into the WARN line via `toLoggable(_:)`
// (`Sources/ConvertSwiftSDKCore/Logging/ToLoggable.swift`), whose `stripSecretQueryParams(from:)`
// regex today only matches `sdkKeySecret` / `sdkKey` — NOT `debug_token`.
//
// This file fails to compile until `ConvertConfiguration.debugToken` exists (GREEN, qs-02 IOS-1)
// — the same RED signal as `ConfigFetchServiceTests.swift`. Once it compiles, the assertion
// itself is EXPECTED TO GENUINELY FAIL today (not merely fail to compile): the WARN line will
// contain the raw token, because the redaction gap in `ToLoggable.swift` has not yet been closed.
// GREEN must widen the redaction (or add an equivalent) so this test passes.
//
// A REAL `URLSessionHTTPClient` over a stubbed `URLSession` (NOT `MockHTTPClient`) is required —
// only a genuine `URLSession` transport error carries the failing-URL `userInfo` that reproduces
// the actual leak; a hand-thrown `URLError` from `MockHTTPClient` would not exercise that
// Foundation behavior and would give a false pass.
import Testing
import Foundation
@testable import ConvertSwiftSDK

// Nested under the shared `.serialized` `URLProtocolStubBackedTests` parent (declared in
// `Adapters/URLSessionHTTPClientTests.swift`) — this suite drives the PROCESS-GLOBAL
// `URLProtocolStub`, whose registries are wiped wholesale by any `reset()`. A separate top-level
// `.serialized` suite would still run in PARALLEL relative to the other stub-driving suites
// (`.serialized` orders only WITHIN a suite), so nesting here is what closes that cross-suite
// race — mirroring `FullChainIntegrationTests.swift`'s identical nesting rationale.
extension URLProtocolStubBackedTests {

/// `.serialized` (belt-and-suspenders atop the parent's scope) — drives the process-global
/// `URLProtocolStub` and resets it at construction AND teardown. A `final class` (not `struct`)
/// so `deinit` can run the after-each reset AND remove this suite's temp cache directory,
/// mirroring `ConfigFetchServiceTests`'s NFR21 cleanup discipline.
@Suite("DebugTokenRedaction", .serialized)
final class DebugTokenRedactionTests {
    /// The QA debug token this suite proves never leaks in clear.
    private static let debugToken = "qa-secret-token-xyz"
    /// SDK key for the configuration under test.
    private static let sdkKey = "sk_preview_test"

    /// The unique temp cache directory this test's `ConfigFetchService` is wired to — never the
    /// real Application Support location. Removed in `deinit`.
    private let cacheDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    /// Resets the process-global `URLProtocolStub` before each test (fresh suite instance per
    /// `@Test`), so no registry entry leaks in from a prior case.
    init() {
        URLProtocolStub.reset()
    }

    /// Resets `URLProtocolStub` again and removes this suite's temp cache directory, so nothing
    /// leaks into an unrelated suite or a later run (NFR21).
    deinit {
        URLProtocolStub.reset()
        try? FileManager.default.removeItem(at: cacheDir)
    }

    /// AC3 — token hygiene (redaction). Builds a REAL stub-backed `URLSessionHTTPClient`, a
    /// `ConvertConfiguration` carrying a `debugToken`, and a `ConfigFetchService` over a unique
    /// temp `cacheURL`. Resolves the URL to stub via the service's own `buildConfigURL()` (never
    /// hand-constructed, so the test never depends on query-item ordering), registers a transport
    /// FAILURE against it, calls `fetchLiveConfig()`, and asserts: (1) the fetch degrades to
    /// `nil` as documented, (2) at least one WARN was logged, and (3) NONE of the logged messages
    /// contain the raw token value or the `debug_token=` substring.
    @Test("fetchLiveConfig's failure WARN never leaks the debugToken value or the debug_token= param")
    func warnLineDoesNotLeakDebugToken() async throws {
        let configuration = ConvertConfiguration(sdkKey: Self.sdkKey, debugToken: Self.debugToken)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        URLProtocolStub.install(into: sessionConfiguration)
        let session = URLSession(configuration: sessionConfiguration)
        let httpClient = URLSessionHTTPClient(session: session, sdkVersion: "test")
        let logger = MockLogger()
        let cacheURL = cacheDir.appendingPathComponent("config-cache.json")
        let service = ConfigFetchService(
            httpClient: httpClient,
            fileStore: CoordinatedFileStore(),
            configuration: configuration,
            logger: logger,
            cacheURL: cacheURL
        )

        let url = try service.buildConfigURL()
        URLProtocolStub.stubFailure(url: url, error: URLError(.cannotConnectToHost))

        let config = await service.fetchLiveConfig()

        #expect(config == nil)
        let entries = logger.entries()
        #expect(!entries.isEmpty, "expected the network-failure path to log at least one WARN")
        for entry in entries {
            #expect(!entry.message.contains(Self.debugToken))
            #expect(!entry.message.contains("debug_token="))
        }
    }
}

} // extension URLProtocolStubBackedTests
