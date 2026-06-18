// HTTPClient.swift
// Port: foreground HTTP transport.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Foreground HTTP transport used for configuration fetches and foreground event delivery.
///
/// The concrete adapter (Epic 2, living in `ConvertSDK/Adapters/`) wraps the platform
/// networking stack; this port states only the request/response contract. The returned
/// tuple pairs the raw body `Data` with its `HTTPURLResponse` so callers can branch on
/// status codes and headers. All parameter and return types (`URL`, `Data`,
/// `HTTPURLResponse`, `[String: String]`) are `Sendable`, so the port composes cleanly
/// under Swift 6 strict concurrency.
public protocol HTTPClient: Sendable {
    /// Performs a GET request and returns the response body paired with its HTTP response.
    func get(url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse)

    /// Performs a POST request with the given body and returns the response body paired
    /// with its HTTP response.
    func post(url: URL, headers: [String: String], body: Data) async throws -> (Data, HTTPURLResponse)
}
