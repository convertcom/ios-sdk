// Tests/ConvertSwiftSDKTests/Adapters/URLSessionEventUploaderTests.swift
//
// AC3 regression lock (qs-02 IOS-1 — token hygiene). `URLSessionEventUploader.upload(_:)`
// (`Sources/ConvertSwiftSDK/Adapters/URLSessionEventUploader.swift`) POSTs to
// `"{trackEndpoint}/track/{sdkKey}"` with `headers: [:]` and NEVER receives a
// `ConvertConfiguration` (or a `debugToken`) at all — there is structurally no path for a debug
// token to reach a track request. This test is EXPECTED TO PASS TODAY: no production changes are
// needed for it to go green. It locks in a currently-true structural invariant so a future change
// cannot silently introduce a debug-token leak on the track path, unlike the other two files in
// this qs-02 IOS-1 RED batch (`ConfigFetchServiceTests.swift`,
// `DebugTokenRedactionTests.swift`), which fail to compile pending `ConvertConfiguration.debugToken`.
//
// Uses `MockHTTPClient` (NOT `URLProtocolStub`) — `URLSessionEventUploader` is exercised entirely
// through the `HTTPClient` port, so no process-global stub is needed and this suite is
// parallel-safe (no nesting under `URLProtocolStubBackedTests`).
import Testing
import Foundation
@testable import ConvertSwiftSDK

@Suite("URLSessionEventUploader token hygiene")
struct URLSessionEventUploaderTests {
    /// The event-delivery base URL the uploader POSTs under (no trailing slash).
    private static let trackEndpoint = "https://track.test/api/v1"
    /// The project SDK key that scopes the delivery route.
    private static let sdkKey = "fc-key"

    /// Builds a 200 `HTTPURLResponse` for the shared track URL.
    private func okResponse(for url: URL) -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        ) else {
            preconditionFailure("HTTPURLResponse(statusCode:200) is non-failing for a valid URL")
        }
        return response
    }

    /// AC3 regression lock. Uploads a drained batch through the uploader over a `MockHTTPClient`
    /// canned with a 200, then asserts the ONE recorded request carries: no query items at all
    /// (`URLComponents(url:).queryItems` nil/empty), no `"debug_token"` substring anywhere in the
    /// absolute URL string, and no header key or value containing `"debug_token"`.
    @Test("upload's POST carries no debug_token in its URL or headers")
    func uploadCarriesNoDebugTokenInURLOrHeaders() async throws {
        guard let trackURL = URL(string: "\(Self.trackEndpoint)/track/\(Self.sdkKey)") else {
            Issue.record("Failed to construct track URL")
            return
        }
        let httpClient = MockHTTPClient(response: (Data(), okResponse(for: trackURL)))
        let uploader = URLSessionEventUploader(
            httpClient: httpClient,
            trackEndpoint: Self.trackEndpoint,
            sdkKey: Self.sdkKey
        )
        let batch = makeTrackingBatch(
            events: [],
            visitorId: "visitor-1",
            accountId: "acc-1",
            projectId: "p-1"
        )

        try await uploader.upload([batch])

        let requests = await httpClient.requests
        let request = try #require(requests.first, "the uploader issued no request to the transport")
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        #expect(components?.queryItems == nil || components?.queryItems?.isEmpty == true)
        #expect(!request.url.absoluteString.contains("debug_token"))
        let headerLeaksDebugToken = request.headers.contains { key, value in
            key.contains("debug_token") || value.contains("debug_token")
        }
        #expect(!headerLeaksDebugToken)
    }
}
