// ConfigFetchService.swift
// Config-fetch coordinator (Epic 2, Story 3): builds the config URL, fetches the
// live config (write-through caching the RAW response bytes), and loads / repairs the
// on-disk cache. Lives in the `ConvertSDK` (platform) target because it composes the
// Foundation-backed `CoordinatedFileStore`; the ports it depends on (`HTTPClient`,
// `Logger`) are Foundation-only and live in the pure-logic `ConvertSDKCore`.

import ConvertSDKCore
import Foundation

/// Coordinates the project-config fetch + local cache for the SDK.
///
/// A `Sendable` value: every stored property is an immutable `let` of a `Sendable`
/// type (the `any HTTPClient` / `any Logger` existentials refine `Sendable` ports; the
/// `CoordinatedFileStore` is an actor; `ConvertConfiguration` and `URL` are value
/// types), so the compiler proves data-race safety with NO `@unchecked` suppression.
///
/// ── Inherited contract: RAW-byte write-through (#4 — the critical behavior) ───────
/// On a successful fetch the service writes the VERBATIM bytes returned by `get()` to
/// the cache — NOT a re-encode of the decoded ``ProjectConfig``. A re-encode would
/// reorder keys, so the on-disk cache must be the exact wire payload to remain a
/// faithful replay of what the CDN served (`fetchLiveConfigWritesRawBytesToCache`
/// asserts byte-for-byte equality).
///
/// ── Failure posture ───────────────────────────────────────────────────────────────
/// Every method returns an optional and NEVER throws to the caller: a network error, a
/// decode failure, or a cache-write failure degrades to `nil` (or, for the write, a
/// logged WARN that still returns the decoded config). A missing cache file is an
/// ordinary miss (silent `nil`); only corrupt cache CONTENT triggers a WARN + delete.
///
/// Conforms to ``ConfigProviding`` (which refines `Sendable`): its existing
/// ``loadCachedConfig()`` / ``fetchLiveConfig()`` satisfy the seam `ConvertSDK.init` injects,
/// so the SDK builds one of these as its production config provider.
public struct ConfigFetchService: ConfigProviding {
    /// Transport used to fetch the live config payload.
    public let httpClient: any HTTPClient
    /// Coordinated on-disk store the cache is read from / written to.
    public let fileStore: CoordinatedFileStore
    /// The immutable configuration driving the URL, auth, and cache path.
    public let configuration: ConvertConfiguration
    /// Structured logging sink for WARNs (never receives the secret or auth value).
    public let logger: any Logger
    /// The on-disk cache path. Injected so tests target a unique temp URL; production
    /// derives it from the SDK key via the convenience initializer below.
    public let cacheURL: URL

    /// Designated initializer with an explicit `cacheURL` — the test seam.
    ///
    /// A Swift default-argument expression cannot reference an earlier parameter
    /// (`configuration`), so the production default for `cacheURL` is supplied by the
    /// convenience initializer below rather than as a default argument here.
    /// - Parameters:
    ///   - httpClient: Transport for the live config fetch.
    ///   - fileStore: Coordinated on-disk cache store.
    ///   - configuration: SDK configuration (drives URL, auth header, cache key).
    ///   - logger: Structured logging sink.
    ///   - cacheURL: On-disk cache path (a unique temp URL in tests).
    public init(
        httpClient: any HTTPClient,
        fileStore: CoordinatedFileStore,
        configuration: ConvertConfiguration,
        logger: any Logger,
        cacheURL: URL
    ) {
        self.httpClient = httpClient
        self.fileStore = fileStore
        self.configuration = configuration
        self.logger = logger
        self.cacheURL = cacheURL
    }

    /// Production initializer: derives `cacheURL` from the configuration's SDK key.
    ///
    /// Forwards to the designated initializer with
    /// ``CoordinatedFileStore/configCacheURL(for:)`` as the cache path — the real
    /// Application Support location tests deliberately never touch.
    /// - Parameters:
    ///   - httpClient: Transport for the live config fetch.
    ///   - fileStore: Coordinated on-disk cache store.
    ///   - configuration: SDK configuration (drives URL, auth header, cache key).
    ///   - logger: Structured logging sink.
    public init(
        httpClient: any HTTPClient,
        fileStore: CoordinatedFileStore,
        configuration: ConvertConfiguration,
        logger: any Logger
    ) {
        self.init(
            httpClient: httpClient,
            fileStore: fileStore,
            configuration: configuration,
            logger: logger,
            cacheURL: CoordinatedFileStore.configCacheURL(for: configuration.sdkKey)
        )
    }

    /// Assembles `{apiConfigEndpoint}/config/{sdkKey}` and appends `environment={value}`
    /// (when set) and `_conv_low_cache=1` (when `networkCacheLevel == .low`).
    ///
    /// `apiConfigEndpoint` carries NO trailing slash (References F-029), so the route
    /// path supplies the leading "/". `URLComponents` joins the query items with "&"
    /// and percent-encodes them; when there are no items the URL has no "?" segment.
    /// - Returns: The fully-built config URL.
    /// - Throws: ``ConvertError/invalidConfiguration(_:)`` if the endpoint string is
    ///   malformed or the components cannot resolve to a URL.
    public func buildConfigURL() throws -> URL {
        guard var components = URLComponents(
            string: configuration.apiConfigEndpoint + "/config/" + configuration.sdkKey
        ) else {
            throw ConvertError.invalidConfiguration("Malformed config endpoint URL")
        }
        var items: [URLQueryItem] = []
        if let env = configuration.environment {
            items.append(URLQueryItem(name: "environment", value: env))
        }
        if configuration.networkCacheLevel == .low {
            items.append(URLQueryItem(name: "_conv_low_cache", value: "1"))
        }
        if !items.isEmpty {
            components.queryItems = items
        }
        guard let url = components.url else {
            throw ConvertError.invalidConfiguration("Could not build config URL")
        }
        return url
    }

    /// Emits one WARN line tagged to this service and the originating `method`.
    ///
    /// Centralizes the level/type and the `toLoggable` redaction so every WARN in this
    /// service routes its detail through the secret-stripping contract (NFR6) and the
    /// line shape cannot drift across call sites. The `detail` is redacted here — call
    /// sites pass the raw error/cause string.
    /// - Parameters:
    ///   - method: The originating method name (the `{method}` field of the log line).
    ///   - reason: A short human cause; the `detail` is appended, redacted.
    ///   - detail: The raw cause string (error description); redacted via `toLoggable`.
    private func warn(method: String, reason: String, detail: String) {
        logger.log(
            level: .warn,
            type: "ConfigFetchService",
            method: method,
            message: "\(reason) — \(toLoggable(detail))"
        )
    }

    /// Reads + decodes the on-disk cache, repairing it when the bytes are corrupt.
    ///
    /// A MISSING cache file is an ordinary miss: `read` throws, and this returns `nil`
    /// silently (nothing to log, nothing to delete). When the read SUCCEEDS but the
    /// bytes fail to decode (corrupt content), a WARN is logged, the corrupt file is
    /// deleted (so the next load re-fetches), and `nil` is returned (AC4).
    /// - Returns: The decoded config, or `nil` on a miss / corrupt cache.
    public func loadCachedConfig() async -> ProjectConfig? {
        let data: Data
        do {
            data = try await fileStore.read(from: cacheURL)
        } catch {
            // Missing cache file → ordinary miss. No log, no delete (nothing to delete).
            return nil
        }
        do {
            // Single decoder, NO keyDecodingStrategy (AR13): ProjectConfig maps wire
            // snake_case via explicit CodingKeys, so .convertFromSnakeCase is forbidden.
            return try JSONDecoder().decode(ProjectConfig.self, from: data)
        } catch {
            warn(
                method: "loadCachedConfig",
                reason: "corrupt cache discarded",
                detail: String(describing: error)
            )
            await fileStore.delete(at: cacheURL)
            return nil
        }
    }

    /// Fetches the live config, write-through caching the RAW response bytes.
    ///
    /// Sequence: build the URL → GET (with a `Bearer` auth header iff a non-empty
    /// `sdkKeySecret` is set) → decode the body → write the VERBATIM `data` from `get()`
    /// to the cache → return the decoded config. Every failure stage degrades to `nil`,
    /// EXCEPT a cache-write failure, which is non-fatal (logged WARN, still returns the
    /// decoded config). The secret and the `Authorization` value are NEVER logged.
    /// - Returns: The decoded config on success, or `nil` on URL-build / network /
    ///   decode failure.
    public func fetchLiveConfig() async -> ProjectConfig? {
        let url: URL
        do {
            url = try buildConfigURL()
        } catch {
            warn(
                method: "fetchLiveConfig",
                reason: "could not build config URL",
                detail: String(describing: error)
            )
            return nil
        }

        // Auth header only when a non-empty secret is configured. The secret value is
        // never logged, and `toLoggable` strips any sk_/secret material from error text.
        var headers: [String: String] = [:]
        if let secret = configuration.sdkKeySecret, !secret.isEmpty {
            headers["Authorization"] = "Bearer \(secret)"
        }

        // CAPTURE the raw `data` here — it is what gets written through to the cache.
        let data: Data
        do {
            (data, _) = try await httpClient.get(url: url, headers: headers)
        } catch {
            warn(
                method: "fetchLiveConfig",
                reason: "config fetch failed",
                detail: String(describing: error)
            )
            return nil
        }

        // Decode the SAME raw bytes (single decoder, NO keyDecodingStrategy — AR13).
        let config: ProjectConfig
        do {
            config = try JSONDecoder().decode(ProjectConfig.self, from: data)
        } catch {
            warn(
                method: "fetchLiveConfig",
                reason: "config decode failed",
                detail: String(describing: error)
            )
            return nil
        }

        // Write-through the VERBATIM response bytes (inherited contract #4): the exact
        // `data` from get(), NOT a re-encode of `config`. A write failure is non-fatal —
        // log a WARN and still return the decoded config.
        do {
            try await fileStore.write(data, to: cacheURL)
        } catch {
            warn(
                method: "fetchLiveConfig",
                reason: "cache write failed",
                detail: String(describing: error)
            )
        }

        return config
    }
}
