// URLSessionEventUploader.swift
// Concrete `EventUploader` adapter (Epic 5 / Story 1): ships a foreground tracking batch
// through the `HTTPClient` port. Lives in the `ConvertSwiftSDK` target because it composes the
// URLSession-backed transport; the port it conforms to is Foundation-only and lives in the
// pure-logic `ConvertSwiftSDKCore`.

import ConvertSwiftSDKCore
import Foundation

/// Delivers a drained tracking batch to the Convert serving API over the foreground transport.
///
/// The batch is routed through the injected ``HTTPClient`` — never a raw `URLSession` — so the
/// SDK's non-overridable `ConvertAgent/<version>` User-Agent is applied by ``URLSessionHTTPClient``
/// (this adapter sets no User-Agent of its own). The ``EventQueue`` always drains to a SINGLE
/// envelope (one account/project), so the wire body is that ONE ``TrackingEvent`` OBJECT — matching
/// the JS SDK's `releaseQueue`, which posts one `{accountId, projectId, enrichData, source,
/// visitors:[…]}` object, NOT a JSON array.
///
/// Concurrency shape: a `final class` whose every stored property is a `let` over a `Sendable`
/// dependency, so it is `Sendable` with NO suppression.
final class URLSessionEventUploader: EventUploader {
    /// The foreground transport the batch is POSTed through (applies the ConvertAgent UA).
    private let httpClient: any HTTPClient
    /// The event-delivery base URL, with NO trailing slash (the route below carries the leading "/").
    private let trackEndpoint: String
    /// The project SDK key that scopes the delivery route.
    private let sdkKey: String

    /// Wires the uploader to its transport, endpoint, and SDK key.
    ///
    /// - Parameters:
    ///   - httpClient: The foreground transport the batch is POSTed through.
    ///   - trackEndpoint: The event-delivery base URL (no trailing slash).
    ///   - sdkKey: The project SDK key that scopes the delivery route.
    init(httpClient: any HTTPClient, trackEndpoint: String, sdkKey: String) {
        self.httpClient = httpClient
        self.trackEndpoint = trackEndpoint
        self.sdkKey = sdkKey
    }

    /// POSTs the single drained envelope to `{trackEndpoint}/track/{sdkKey}`.
    ///
    /// An empty batch is a no-op. The body is the lone ``TrackingEvent`` OBJECT (not the array) so
    /// the wire matches the JS `releaseQueue` shape. The default key strategy is used — NEVER
    /// `.convertToSnakeCase` (AR13), since the model's explicit camelCase `CodingKeys` are the wire
    /// contract. A non-2xx response throws so the ``EventQueue``'s flush re-enqueues the batch.
    ///
    /// - Parameter events: The drained batch — a single-element array from the ``EventQueue``.
    /// - Throws: `URLError(.badURL)` if the route is malformed, or `URLError(.badServerResponse)`
    ///   on a non-2xx HTTP status.
    func upload(_ events: [TrackingEvent]) async throws {
        guard let envelope = events.first else { return }
        guard let url = URL(string: "\(trackEndpoint)/track/\(sdkKey)") else {
            throw URLError(.badURL)
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        let body = try encoder.encode(envelope)
        let (_, response) = try await httpClient.post(url: url, headers: [:], body: body)
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
