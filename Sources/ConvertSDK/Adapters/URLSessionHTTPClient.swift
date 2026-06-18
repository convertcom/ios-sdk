// URLSessionHTTPClient.swift
// Concrete `HTTPClient` adapter (Epic 2, Story 2.3): wraps `URLSession` for the
// foreground configuration fetch and foreground event delivery. Lives in the
// `ConvertSDK` target because it depends on Foundation networking; the port it
// conforms to is Foundation-only and lives in the pure-logic `ConvertSDKCore`.

import ConvertSDKCore
import Foundation

/// `URLSession`-backed implementation of the `HTTPClient` port for foreground config
/// fetches and event delivery.
///
/// An infrastructure adapter, not part of the everyday decisioning API — it is `public`
/// only so it can be injected for dependency-injection and testing. The SDK always stamps
/// its own `User-Agent` (`ConvertAgent/<version>`) on every outbound request, applied after
/// the caller's headers so it always wins (a caller-supplied `User-Agent` is overwritten,
/// never appended). `@unchecked Sendable`: `URLSession` is thread-safe and the stored
/// session is immutable after `init`.
public final class URLSessionHTTPClient: @unchecked Sendable, HTTPClient {
    /// The session every request is issued through. Immutable after init; tests inject
    /// a stub-installed session, production uses ``makeDefaultSession()``.
    private let session: URLSession

    /// SDK version stamped into the outbound `User-Agent`. Injected (the
    /// `ConfigFetchService` passes `SDKVersion.current`), never hardcoded here.
    private let sdkVersion: String

    /// Wires the client to a session and the SDK version used in its `User-Agent`.
    /// The default session is built by ``makeDefaultSession()`` with FR45-bounded
    /// timeouts; tests inject their own stub-installed session, so the default is
    /// only used in production.
    public init(
        session: URLSession = URLSessionHTTPClient.makeDefaultSession(),
        sdkVersion: String
    ) {
        self.session = session
        self.sdkVersion = sdkVersion
    }

    /// Performs a GET and returns the body paired with its `HTTPURLResponse`.
    ///
    /// Status-code branching (non-2xx handling) is the caller layer's concern in a
    /// later task — this returns `(data, http)` for ANY HTTP response.
    public func get(url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        // Caller headers FIRST…
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // …SDK User-Agent LAST: `setValue` REPLACES (not `addValue`, which appends),
        // so it overwrites any caller-supplied `User-Agent` and always wins.
        request.setValue("ConvertAgent/\(sdkVersion)", forHTTPHeaderField: "User-Agent")

        // R2/FR44: `URLSession.data(for:)` resumes EXACTLY ONCE by Swift's language
        // contract (success, transport error, or cancellation), so no manual
        // `withCheckedContinuation` is needed to bound the await.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConvertError.invalidConfiguration("Non-HTTP response from config endpoint")
        }
        return (data, http)
    }

    /// Performs a POST with `body` and returns the body paired with its
    /// `HTTPURLResponse`. Header ordering and response handling mirror ``get(url:headers:)``.
    ///
    /// Story 2.3 scope is `get`; `post` is required by the ``HTTPClient`` protocol and
    /// implemented symmetrically so the adapter compiles and is correct (exercised in Epic 5).
    public func post(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        // Caller headers FIRST, SDK User-Agent LAST (replace, always wins) — as in `get`.
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("ConvertAgent/\(sdkVersion)", forHTTPHeaderField: "User-Agent")

        // R2/FR44: `URLSession.data(for:)` resumes exactly once (success / transport
        // error / cancellation) — no manual continuation needed to bound the await.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConvertError.invalidConfiguration("Non-HTTP response from config endpoint")
        }
        return (data, http)
    }

    /// Builds the production session: a `URLSessionConfiguration` whose request and
    /// resource timeouts are the FR45-bounded ``Defaults`` values (NOT the 7-day
    /// URLSession defaults), wrapped in a `URLSession`.
    ///
    /// `public` (not `private`): it is referenced from the default argument value of the
    /// `public init`. A default-argument expression is evaluated at the call site, so for
    /// a `public` initializer it may reference only `public` declarations — Swift rejects
    /// `private` and `internal` here. `public` is therefore the only access level that
    /// satisfies the mandated `public init(session: … = makeDefaultSession(), …)` shape.
    public static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Defaults.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = Defaults.resourceTimeoutSeconds
        return URLSession(configuration: configuration)
    }
}
