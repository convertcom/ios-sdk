// Tests/ConvertSDKTests/URLProtocolStubTests.swift
import Testing
import Foundation
import ConvertSDK

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
