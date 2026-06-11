// URLProtocolStub.swift
// A `URLProtocol` subclass that intercepts `URLSession` requests and serves
// caller-configured canned responses, so the HTTP-dependent test suites across
// Epics 2–5 never need a live server (Story 1.3, Task 2.2, AC7/AC9).
//
// Usage: `install(into:)` prepends this protocol to a `URLSessionConfiguration`'s
// `protocolClasses`, `stub(url:statusCode:data:headers:)` registers a canned
// response keyed on the absolute URL string, `stubFailure(url:error:)` registers a
// transport-level failure for a URL (the load is failed with the given `URLError`
// rather than answered), and `reset()` clears all registries plus the captured
// request (call it first in every test — NFR21 forbids state leaking between cases).
// A request whose URL has neither a stub nor a failure registered falls back to a
// 404 response with an empty body (a real HTTP response, NOT a transport error), so
// an un-stubbed call surfaces as a server-style miss rather than a thrown `URLError`.
// Every intercepted request is recorded in `capturedRequests`, keyed on its absolute
// URL string, so a test can assert what the client actually sent to a given endpoint
// (e.g. the outbound `User-Agent` header) — read it back with `recordedRequest(for:)`.
//
// ── Concurrency shape (AC9) ───────────────────────────────────────────────────
// `URLProtocol` is an `NSObject` subclass, so `URLProtocolStub` CANNOT be an
// `actor`, and the state the framework reads from / writes to in `startLoading()`
// is inherently PROCESS-GLOBAL: `URLProtocol` is instantiated by the loading
// system, not by the test, so that state must be CLASS-LEVEL `static` mutable
// storage. Three pieces share this shape — the response registry `handlers`, the
// failure registry `failures`, and the captured-request registry `capturedRequests`.
//
// That static storage needs `nonisolated(unsafe)`, applied to exactly those three
// declarations and nothing else. It is unavoidable here because:
//   * the `NSObject` inheritance rules out an `actor`, forcing static state;
//   * `Synchronization.Mutex` (the annotation-free Sendable lock cell) is
//     `@available(iOS 18, *)`, but this package's deployment floor is iOS 15 /
//     macOS 12 (see Package.swift `platforms`), so `Mutex` is unavailable; and
//   * a plain `NSLock`-guarded `static var` does not satisfy Swift 6 strict
//     concurrency's global-mutable-state checking, because the compiler cannot
//     see the runtime lock.
// The annotations are sound because EVERY read and write of all three goes through
// the single shared `lock.withLock`, so all accesses are mutually exclusive at
// runtime; the audit surface is exactly the accessors below. AC9 explicitly permits
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
    /// One of three `nonisolated(unsafe)` declarations in the file (see the file
    /// header for why they are structurally unavoidable: `NSObject` subclass +
    /// iOS 15 floor where `Synchronization.Mutex` is unavailable). Sound because
    /// every access below is serialized through ``lock``.
    private nonisolated(unsafe) static var handlers: [String: StubResponse] = [:]

    /// Process-global registry of transport-level failures, keyed on
    /// `url.absoluteString`. When a URL is registered here, ``startLoading()`` fails
    /// the load with the stored `URLError` instead of answering it — exercising the
    /// client's error path (e.g. the body-read-throws / no-hang contract). A failure
    /// registered for a URL takes precedence over any response stub for the same URL.
    /// Guarded by ``lock`` exactly like ``handlers`` (see the file header).
    private nonisolated(unsafe) static var failures: [String: URLError] = [:]

    /// Process-global registry of intercepted requests, keyed on `url.absoluteString`,
    /// recorded so a test can assert what the client actually sent to a given endpoint
    /// (e.g. the outbound `User-Agent` header, which Foundation surfaces on the
    /// intercepted request when the caller sets it explicitly via
    /// `setValue(_:forHTTPHeaderField:)`). Guarded by ``lock`` exactly like
    /// ``handlers`` (see the file header). Cleared by ``reset()``.
    ///
    /// Keyed — not a single slot — for the SAME reason ``handlers`` and ``failures``
    /// are keyed: swift-testing runs different `@Suite`s in PARALLEL, and `.serialized`
    /// only orders cases WITHIN a suite, not across suites. A single shared slot would
    /// be clobbered by a concurrently-running suite that intercepts a DIFFERENT URL
    /// between this suite's request and its read-back, producing a cross-suite flake.
    /// Keying by URL gives each suite the same immunity ``handlers``/``failures``
    /// already have: it reads back only the request for the URL it itself drove.
    private nonisolated(unsafe) static var capturedRequests: [String: URLRequest] = [:]

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

    /// Registers a transport-level failure for `url`: a request to it fails the
    /// load with `error` instead of producing an `HTTPURLResponse`. Models the
    /// network-error path (connection lost, body read failed, …) so the client's
    /// throwing / no-hang behavior can be exercised. Takes precedence over any
    /// response stub for the same URL.
    static func stubFailure(url: URL, error: URLError) {
        lock.withLock { failures[url.absoluteString] = error }
    }

    /// The intercepted request whose URL matches `url`, or `nil` if none has been
    /// recorded for that URL since the last ``reset()``. Read under ``lock``. Lets a
    /// test assert the outbound request the client built (headers, method, URL) for a
    /// specific endpoint. Keyed by `url.absoluteString` so a concurrently-running
    /// suite hitting a different URL cannot corrupt this suite's read-back.
    static func recordedRequest(for url: URL) -> URLRequest? {
        lock.withLock { capturedRequests[url.absoluteString] }
    }

    /// Clears every registry (responses and failures) and the captured request,
    /// restoring the empty initial state.
    static func reset() {
        lock.withLock {
            handlers.removeAll()
            failures.removeAll()
            capturedRequests.removeAll()
        }
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
        // Record the intercepted request before answering it, so a test can assert
        // what the client sent. Done under the same lock as the lookups below.
        let capturedRequest = request

        guard let url = request.url else {
            // No URL to key the capture by; nothing asserts the nil-URL request, so
            // skip keyed capture and just fail the load (badURL) as before.
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        // One critical section: capture the request (keyed by URL) and resolve both
        // registries so the lock is taken once and the failure/stub decision is
        // consistent.
        let (failure, matched): (URLError?, StubResponse?) = Self.lock.withLock {
            Self.capturedRequests[url.absoluteString] = capturedRequest
            return (Self.failures[url.absoluteString], Self.handlers[url.absoluteString])
        }

        if let failure {
            // Registered transport failure: fail the load with the given error.
            // Takes precedence over any response stub for the same URL.
            client?.urlProtocol(self, didFailWithError: failure)
        } else if let matched {
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
