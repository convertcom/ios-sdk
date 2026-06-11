// URLProtocolStub.swift
// A `URLProtocol` subclass that intercepts `URLSession` requests and serves
// caller-configured canned responses, so the HTTP-dependent test suites across
// Epics 2–5 never need a live server (Story 1.3, Task 2.2, AC7/AC9).
//
// Usage: `install(into:)` prepends this protocol to a `URLSessionConfiguration`'s
// `protocolClasses`, `stub(url:statusCode:data:headers:)` registers a canned
// response keyed on the absolute URL string, and `reset()` clears the registry
// (call it first in every test — NFR21 forbids state leaking between cases).
// A request whose URL has no registered stub falls back to a 404 response with an
// empty body (a real HTTP response, NOT a transport error), so an un-stubbed call
// surfaces as a server-style miss rather than a thrown `URLError`.
//
// ── Concurrency shape (AC9) ───────────────────────────────────────────────────
// `URLProtocol` is an `NSObject` subclass, so `URLProtocolStub` CANNOT be an
// `actor`, and the handler registry the framework reads from `startLoading()` is
// inherently PROCESS-GLOBAL: `URLProtocol` is instantiated by the loading system,
// not by the test, so the registry must be CLASS-LEVEL `static` mutable state.
//
// That static storage needs `nonisolated(unsafe)` — it is the ONE annotation in
// this file, applied to `handlers` alone. It is unavoidable here because:
//   * the `NSObject` inheritance rules out an `actor`, forcing static state;
//   * `Synchronization.Mutex` (the annotation-free Sendable lock cell) is
//     `@available(iOS 18, *)`, but this package's deployment floor is iOS 15 /
//     macOS 12 (see Package.swift `platforms`), so `Mutex` is unavailable; and
//   * a plain `NSLock`-guarded `static var` does not satisfy Swift 6 strict
//     concurrency's global-mutable-state checking, because the compiler cannot
//     see the runtime lock.
// The annotation is sound because EVERY read and write of `handlers` goes through
// `lock.withLock`, so all accesses are mutually exclusive at runtime; the audit
// surface is exactly the three accessors below. AC9 explicitly permits
// `nonisolated(unsafe)` "where URLProtocol's inheritance model makes it
// unavoidable" — this is precisely that case.

import Foundation

final class URLProtocolStub: URLProtocol {
    /// One registered canned response. `Sendable` so it can be stored in the
    /// process-global registry under Swift 6 strict concurrency.
    private struct StubResponse: Sendable {
        let statusCode: Int
        let data: Data?
        let headers: [String: String]
    }

    /// Serializes every access to ``handlers``. A `let`, so it needs no
    /// concurrency annotation.
    private static let lock = NSLock()

    /// Process-global registry of canned responses, keyed on `url.absoluteString`.
    ///
    /// This is the only `nonisolated(unsafe)` declaration in the file (see the
    /// file header for why it is structurally unavoidable: `NSObject` subclass +
    /// iOS 15 floor where `Synchronization.Mutex` is unavailable). It is sound
    /// because every access below is serialized through ``lock``.
    private nonisolated(unsafe) static var handlers: [String: StubResponse] = [:]

    // MARK: - Registration

    /// Inserts `URLProtocolStub` at the front of the configuration's
    /// `protocolClasses` so it intercepts requests before the default handlers.
    static func install(into configuration: URLSessionConfiguration) {
        var classes = configuration.protocolClasses ?? []
        classes.insert(URLProtocolStub.self, at: 0)
        configuration.protocolClasses = classes
    }

    /// Registers a canned response for `url`, keyed on its absolute string.
    /// A later stub for the same URL replaces the earlier one.
    static func stub(url: URL, statusCode: Int, data: Data?, headers: [String: String]) {
        let response = StubResponse(statusCode: statusCode, data: data, headers: headers)
        lock.withLock { handlers[url.absoluteString] = response }
    }

    /// Clears all registered handlers, restoring the empty registry.
    static func reset() {
        lock.withLock { handlers.removeAll() }
    }

    // MARK: - URLProtocol overrides

    /// Intercept every request once installed; the registry decides whether a
    /// concrete stub or the 404 fallback answers it.
    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    /// No canonicalization — the request is used verbatim.
    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let matched = Self.lock.withLock { Self.handlers[url.absoluteString] }

        if let matched {
            sendResponse(
                url: url,
                statusCode: matched.statusCode,
                headers: matched.headers,
                body: matched.data
            )
        } else {
            // No registered stub: answer with a real 404 response and an empty
            // body. Deliberately NOT a transport error — the test expects a 404
            // RESPONSE for an un-stubbed URL, not a thrown `URLError`.
            sendResponse(url: url, statusCode: 404, headers: [:], body: nil)
        }
    }

    /// Synchronous canned responses complete inside `startLoading()`, so there is
    /// nothing to cancel.
    override func stopLoading() {}

    // MARK: - Response emission

    /// Builds and emits an `HTTPURLResponse` for `url`, optionally followed by
    /// `body`, then finishes loading. `HTTPURLResponse(...)` is failable; if it
    /// returns `nil` the load is failed cleanly rather than force-unwrapped.
    private func sendResponse(
        url: URL,
        statusCode: Int,
        headers: [String: String],
        body: Data?
    ) {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
