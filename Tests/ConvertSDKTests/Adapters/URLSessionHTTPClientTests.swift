// Tests/ConvertSDKTests/Adapters/URLSessionHTTPClientTests.swift
import Testing
import Foundation
import ConvertSDK

// RED phase (Epic 2, Story 2.3): this suite exercises `URLSessionHTTPClient`, the
// concrete `HTTPClient` adapter, which DOES NOT EXIST YET — the GREEN step creates
// it at `Sources/ConvertSDK/Adapters/URLSessionHTTPClient.swift`. Until then this
// file fails to compile with "cannot find 'URLSessionHTTPClient' in scope", which
// is the expected RED state for this TDD cycle. (The `URLProtocolStub` extension
// these tests rely on — request capture + transport-failure stubbing — already
// compiles; only the `URLSessionHTTPClient` references are unresolved.)
//
// `.serialized`: like `URLProtocolStubTests`, this suite drives `URLProtocolStub`,
// whose registries and captured request are PROCESS-GLOBAL. swift-testing runs
// `@Test` cases in parallel by default; serializing eliminates the cross-test race
// on that shared state. `init()` / `deinit` additionally call
// `URLProtocolStub.reset()` so every case starts AND ends with a clean registry
// (NFR21 — no state leaks between tests).
//
// ── UA-capture mechanism (for the GREEN implementer) ──────────────────────────
// The two header tests assert on `URLProtocolStub.recordedRequest()`'s
// `value(forHTTPHeaderField: "User-Agent")`. This was verified empirically on the
// project toolchain (Swift 6.2.3 / macOS): when the caller sets `User-Agent`
// explicitly on the `URLRequest` via `setValue(_:forHTTPHeaderField:)`, the
// intercepting `URLProtocol` sees that exact value on `request` (both via
// `value(forHTTPHeaderField:)` and `allHTTPHeaderFields`), and a second `setValue`
// for the same field overwrites the first. URLSession's *implicit* default
// User-Agent (when the caller sets none) is applied below the protocol and is NOT
// visible — irrelevant here because the SDK always sets it explicitly.
//
// THEREFORE the GREEN `URLSessionHTTPClient.get(...)` MUST, on the `URLRequest` it
// hands to `session.data(for:)`:
//   1. apply the caller's `headers` first (each via `setValue(_:forHTTPHeaderField:)`),
//   2. then set `User-Agent` = "ConvertAgent/\(sdkVersion)" LAST, so it always wins.
// Setting UA via `setValue` (which replaces) — not `addValue` (which appends) — is
// what makes `callerUAIsOverwritten()` pass.
// A `final class` (not `struct`) so the suite can declare a `deinit`: swift-testing
// creates a fresh suite instance per `@Test`, runs `init()` before the test and
// `deinit` after it, giving symmetric before/after-each reset of the process-global
// `URLProtocolStub` state. A `struct` cannot carry a `deinit` (it conforms to
// `Copyable`), so the class form is the sanctioned shape for after-each teardown.
@Suite("URLSessionHTTPClient", .serialized)
final class URLSessionHTTPClientTests {
    /// Endpoint every scenario drives traffic through.
    static let endpoint = URL(string: "https://cdn.convert.example/config")
    /// SDK version the system under test is initialized with; the expected
    /// `User-Agent` is "ConvertAgent/" + this value.
    static let sdkVersion = "9.9.9-test"
    /// Canned 200 payload for the success scenarios.
    static let responseBody = Data(#"{"config":"ok"}"#.utf8)
    /// Prefix every SDK-issued `User-Agent` must start with.
    static let userAgentPrefix = "ConvertAgent/"

    /// Resets the process-global `URLProtocolStub` state before each test (fresh
    /// suite instance per `@Test`), so no registry entry or captured request leaks
    /// in from a prior case.
    init() {
        URLProtocolStub.reset()
    }

    /// Resets again after each test, so this suite never leaves global state behind
    /// for an unrelated suite (NFR21).
    deinit {
        URLProtocolStub.reset()
    }

    /// Builds the system under test wired through a freshly stub-installed session.
    /// Centralizes the configuration → install → `URLSession` → client wiring so no
    /// case copies it (SonarQube new-code duplication discipline). `init()` has
    /// already reset the stub, so the returned client starts from a clean registry.
    private func makeSUT(
        sdkVersion: String = URLSessionHTTPClientTests.sdkVersion
    ) -> URLSessionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        URLProtocolStub.install(into: configuration)
        let session = URLSession(configuration: configuration)
        return URLSessionHTTPClient(session: session, sdkVersion: sdkVersion)
    }

    /// Reads the outbound `User-Agent` the client actually sent on the last request,
    /// failing the test (rather than silently passing on `nil`) if no request was
    /// captured. Shared by the two header assertions so neither repeats the unwrap.
    private func capturedUserAgent(
        _ sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        let request = try #require(
            URLProtocolStub.recordedRequest(),
            "no request was intercepted by the stub",
            sourceLocation: sourceLocation
        )
        return try #require(
            request.value(forHTTPHeaderField: "User-Agent"),
            "intercepted request carried no User-Agent header",
            sourceLocation: sourceLocation
        )
    }

    /// `get` sets `User-Agent` to the SDK value as the LAST header, and the round
    /// trip succeeds (proving the request was actually issued through the session).
    @Test("get sets the ConvertAgent User-Agent as the final header")
    func setsConvertAgentUALast() async throws {
        let sut = makeSUT()
        guard let endpoint = Self.endpoint else {
            Issue.record("Failed to construct endpoint URL")
            return
        }
        URLProtocolStub.stub(
            url: endpoint,
            statusCode: 200,
            data: Self.responseBody,
            headers: [:]
        )

        _ = try await sut.get(url: endpoint, headers: [:])

        let userAgent = try capturedUserAgent()
        #expect(userAgent.hasPrefix(Self.userAgentPrefix))
    }

    /// A caller-supplied `User-Agent` is OVERWRITTEN by the SDK value — the outbound
    /// header is "ConvertAgent/…", never the caller's "custom".
    @Test("a caller-supplied User-Agent is overwritten by the SDK value")
    func callerUAIsOverwritten() async throws {
        let sut = makeSUT()
        guard let endpoint = Self.endpoint else {
            Issue.record("Failed to construct endpoint URL")
            return
        }
        URLProtocolStub.stub(
            url: endpoint,
            statusCode: 200,
            data: Self.responseBody,
            headers: [:]
        )

        _ = try await sut.get(url: endpoint, headers: ["User-Agent": "custom"])

        let userAgent = try capturedUserAgent()
        #expect(userAgent.hasPrefix(Self.userAgentPrefix))
        #expect(userAgent != "custom")
    }

    /// On a 200, `get` returns the stubbed body `Data` and an `HTTPURLResponse`
    /// whose `statusCode` is 200.
    @Test("get returns the body and HTTP response on 200")
    func returnsBodyAndResponseOn200() async throws {
        let sut = makeSUT()
        guard let endpoint = Self.endpoint else {
            Issue.record("Failed to construct endpoint URL")
            return
        }
        URLProtocolStub.stub(
            url: endpoint,
            statusCode: 200,
            data: Self.responseBody,
            headers: ["Content-Type": "application/json"]
        )

        let (data, response) = try await sut.get(url: endpoint, headers: [:])

        #expect(data == Self.responseBody)
        #expect(response.statusCode == 200)
    }

    /// A transport / body-read failure makes `get` THROW rather than hang. The async
    /// `URLSession.data(for:)` resumes exactly once by contract, so awaiting the
    /// throwing call directly is bounded — the test reaching completion (the
    /// `#expect(throws:)` observing the error) IS the no-hang proof. No sleeps, no
    /// wall-clock timeout (NFR22 forbids them).
    @Test("get throws (does not hang) when the transport fails")
    func bodyReadThrowsDoesNotHang() async throws {
        let sut = makeSUT()
        guard let endpoint = Self.endpoint else {
            Issue.record("Failed to construct endpoint URL")
            return
        }
        URLProtocolStub.stubFailure(url: endpoint, error: URLError(.networkConnectionLost))

        await #expect(throws: (any Error).self) {
            _ = try await sut.get(url: endpoint, headers: [:])
        }
    }
}
