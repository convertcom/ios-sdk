// ConfigProviding.swift
// Port: the config-fetch seam `ConvertSwiftSDK.init` injects (Epic 2 / Story 3).
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// Port: supplies the project configuration to ``ConvertSwiftSDK`` from two sources — the on-disk
/// cache and a live network fetch.
///
/// This is the seam `ConvertSwiftSDK.init` injects so a unit test never touches the network: tests
/// pass a mock, production passes the real `ConfigFetchService` (which conforms to this in the
/// `ConvertSwiftSDK` target). It supersedes an earlier `ConfigLoader` seam — instead of a
/// `Void`-returning "config is available" signal, both requirements return a typed
/// ``ProjectConfig?`` so the SDK can hand the actual config to the ``ConfigStore``.
///
/// Both requirements are non-throwing and return an optional: a miss, a transient network
/// failure, or a decode error all degrade to `nil` (the conforming `ConfigFetchService` absorbs
/// every error internally), so `ConvertSwiftSDK.init`'s load task never has to catch — it calls
/// ``loadCachedConfig()`` then ``fetchLiveConfig()`` and feeds each result to the store, which
/// resolves `ready()` degraded when both are `nil`.
///
/// Refines `Sendable` so the existential the init captures crosses into the detached config-load
/// `Task` without a data-race warning (the conformers are an actor in tests and a `Sendable`
/// value struct in production).
public protocol ConfigProviding: Sendable {
    /// Loads the project config from the on-disk cache. Returns `nil` on a cache miss or corrupt
    /// cache content; never throws.
    func loadCachedConfig() async -> ProjectConfig?

    /// Fetches the live project config over the network, write-through caching it. Returns `nil`
    /// on a URL-build / network / decode failure; never throws.
    func fetchLiveConfig() async -> ProjectConfig?
}
