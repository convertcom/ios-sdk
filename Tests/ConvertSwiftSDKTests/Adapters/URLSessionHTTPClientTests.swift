// Tests/ConvertSwiftSDKTests/Adapters/URLSessionHTTPClientTests.swift
//
// MAINTENANCE NOTE (file length): this file is the canonical home for EVERY URLProtocolStub-driving
// suite, because they must all nest under the ONE shared `.serialized` parent (URLProtocolStubBackedTests)
// so they run serially relative to each other (the parent installs `isParallelizationEnabled = false` for
// its whole subtree). Story 5.5 added the RecordedRequestCountTests child here, putting the file AT the
// 400-line file-length limit. A future stub-backed suite added here will breach it — at that point add a
// named file-length lint suppression at the top (mirroring TestFixtures.swift / ConvertContextTests.swift)
// rather than splitting the stub-backed suites across files, which would re-introduce the cross-suite
// reset() race the single parent exists to prevent. (Such a suppression is intentionally NOT present yet:
// the linter rejects it as superfluous until the limit is actually exceeded.)
import Testing
import Foundation
import ConvertSwiftSDK

// `URLProtocolStub`-backed suites, serialized RELATIVE TO EACH OTHER.
//
// Both `URLProtocolStubTests` and `URLSessionHTTPClientTests` drive the same
// `URLProtocolStub`, whose response/failure/captured-request registries are
// PROCESS-GLOBAL. `.serialized` on a `@Suite` only orders cases WITHIN that suite
// — swift-testing still runs different top-level suites in PARALLEL. So although
// each suite was already `.serialized`, a case from one could still interleave
// with a case from the other, and `reset()` (a global `removeAll()` wipe) fired by
// one suite mid-flight would clobber the other suite's just-registered state — a
// cross-suite scheduler flake (~38% of full-suite runs).
//
// Remedy (swift-testing 6.2.3, verified against `ParallelizationTrait`): nesting
// both suites inside ONE `.serialized` parent suite makes them run serially
// relative to each other. The trait's documented contract for a suite is that it
// "runs its contained test functions ... and sub-suites serially instead of in
// parallel. If the sub-suites have children, they also run serially" — and it
// "does not affect the execution of a test relative to ... unrelated tests."
// Mechanically (6.2.3 `ParallelizationTrait: TestScoping`) the parent installs a
// scope with `isParallelizationEnabled = false` via `Configuration.withCurrent`,
// which the Runner inherits into the whole subtree; the 21 unrelated top-level
// suites are outside that scope and stay parallel. The parent is a zero-case
// `enum` used purely as a namespace (no instances, no members) — the idiomatic
// shape for a suite that only groups child suites.
@Suite("URLProtocolStub-backed", .serialized)
enum URLProtocolStubBackedTests {
    // RED phase (Story 1.3, Task 2.4, AC7): this suite exercises `URLProtocolStub`,
    // which does NOT exist yet — the implementation is created in the next step.
    // Until then this file fails to compile with "cannot find 'URLProtocolStub' in
    // scope", which is the expected RED state for this TDD cycle.
    //
    // `.serialized`: `URLProtocol` registration mutates PROCESS-GLOBAL state
    // (the canned-handler registry is shared across the whole process). swift-testing
    // runs `@Test` cases in parallel by default, so two cases racing on that shared
    // registry would be flaky. `.serialized` forces the cases in this suite to run one
    // at a time, eliminating the cross-test global-state race. NFR21 additionally
    // forbids leaking state between tests, so every case calls
    // `URLProtocolStub.reset()` first to start from a clean registry.
    @Suite("URLProtocolStub", .serialized)
    struct URLProtocolStubTests {
        /// Endpoint the stub is registered against in the happy-path scenario.
        static let stubbedURL = URL(string: "https://example.com/stubbed")
        /// Endpoint deliberately left un-stubbed to exercise the 404 no-match fallback.
        static let unstubbedURL = URL(string: "https://example.com/not-stubbed")
        /// Canned JSON payload the happy-path stub returns.
        static let stubbedData = Data(#"{"ok":true}"#.utf8)

        /// Builds an ephemeral session wired to a freshly-reset `URLProtocolStub`.
        /// Shared by the scenarios so neither copies the install/reset block.
        private func makeStubbedSession() -> URLSession {
            URLProtocolStub.reset()
            let configuration = URLSessionConfiguration.ephemeral
            URLProtocolStub.install(into: configuration)
            return URLSession(configuration: configuration)
        }

        /// A request to a stubbed URL returns the canned 200 + body; a request to an
        /// un-stubbed URL falls back to 404 with no body. Parameterized over both
        /// scenarios so the install/reset setup lives in one helper (SonarQube
        /// new-code duplication discipline — no copy-pasted setup block).
        @Test(
            "stubbed URL returns canned response; un-stubbed URL falls back to 404",
            arguments: [
                (
                    requested: URLProtocolStubTests.stubbedURL,
                    expectedStatus: 200,
                    expectedData: URLProtocolStubTests.stubbedData
                ),
                (
                    requested: URLProtocolStubTests.unstubbedURL,
                    expectedStatus: 404,
                    expectedData: Data()
                )
            ]
        )
        func smokeResponse(
            requested: URL?,
            expectedStatus: Int,
            expectedData: Data
        ) async throws {
            let session = makeStubbedSession()

            guard let stubbedURL = Self.stubbedURL, let requested else {
                Issue.record("Failed to construct test URLs")
                return
            }

            URLProtocolStub.stub(
                url: stubbedURL,
                statusCode: 200,
                data: Self.stubbedData,
                headers: ["Content-Type": "application/json"]
            )

            let (data, response) = try await session.data(from: requested)

            let httpResponse = try #require(response as? HTTPURLResponse)
            #expect(httpResponse.statusCode == expectedStatus)
            #expect(data == expectedData)
        }

        /// `reset()` clears previously registered handlers: after stubbing a URL and
        /// then calling `reset()`, the same URL no longer matches and falls back to
        /// 404. Demonstrates the NFR21 teardown contract (no state leaks between tests).
        @Test("reset() clears registered handlers")
        func resetClearsHandlers() async throws {
            let session = makeStubbedSession()

            guard let stubbedURL = Self.stubbedURL else {
                Issue.record("Failed to construct test URL")
                return
            }

            URLProtocolStub.stub(
                url: stubbedURL,
                statusCode: 200,
                data: Self.stubbedData,
                headers: ["Content-Type": "application/json"]
            )
            URLProtocolStub.reset()

            let (data, response) = try await session.data(from: stubbedURL)

            let httpResponse = try #require(response as? HTTPURLResponse)
            #expect(httpResponse.statusCode == 404)
            #expect(data.isEmpty)
        }
    }

    // RED phase (Epic 2, Story 2.3): this suite exercises `URLSessionHTTPClient`, the
    // concrete `HTTPClient` adapter, which DOES NOT EXIST YET — the GREEN step creates
    // it at `Sources/ConvertSwiftSDK/Adapters/URLSessionHTTPClient.swift`. Until then this
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
    // The two header tests assert on `URLProtocolStub.recordedRequest(for:)`'s
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

        /// Reads the outbound `User-Agent` the client actually sent on the request to
        /// `endpoint`, failing the test (rather than silently passing on `nil`) if no
        /// request was captured for that endpoint. Shared by the two header assertions so
        /// neither repeats the unwrap. Takes the endpoint so it reads back the stub's
        /// URL-keyed capture for THIS suite's request — immune to a concurrently-running
        /// suite that intercepts a different URL.
        private func capturedUserAgent(
            for endpoint: URL,
            _ sourceLocation: SourceLocation = #_sourceLocation
        ) throws -> String {
            let request = try #require(
                URLProtocolStub.recordedRequest(for: endpoint),
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

            let userAgent = try capturedUserAgent(for: endpoint)
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

            let userAgent = try capturedUserAgent(for: endpoint)
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

    // RED phase (Epic 5, Story 5.5, T0): this suite exercises
    // `URLProtocolStub.recordedRequestCount(for:)`, the per-URL request COUNT
    // accessor added to `Support/URLProtocolStub.swift`. The existing
    // `recordedRequest(for:)` returns only the LAST request for a URL; the new
    // accessor returns HOW MANY hit it (lock-guarded + `reset()`-aware).
    //
    // It lives HERE — as a third child of the one `URLProtocolStub-backed`
    // `.serialized` parent, alongside `URLProtocolStubTests` and
    // `URLSessionHTTPClientTests` — precisely because it drives the same
    // PROCESS-GLOBAL stub registries (now including the per-URL counter). A
    // SEPARATE top-level `.serialized` suite would still run in PARALLEL relative
    // to these (`.serialized` orders cases WITHIN a suite, never across two
    // top-level parents), so a sibling case's `reset()` (a global wipe) could
    // clobber this suite's tally between its requests and its assertion. Nesting
    // under the shared parent inherits the parent's `isParallelizationEnabled =
    // false` scope, serializing this suite RELATIVE TO the other stub-driving
    // suites — the only thing that closes that cross-suite race (see this file's
    // header for the mechanism). Kept `.serialized` as belt-and-suspenders.
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
