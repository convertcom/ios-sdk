// ConfigLoader.swift
// Port: loads the project configuration for an SDK key.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Port: loads the project configuration for an SDK key.
///
/// The concrete `URLSession`-backed adapter lands in Story 2.3; this story injects a mock.
/// Returns `Void` because there is no `ProjectConfig` type yet (the typed shape is Story
/// 2.3's scope) — success simply means "config is available", which the SDK signals to the
/// ``ConfigStore``.
public protocol ConfigLoader: Sendable {
    /// Loads the project configuration for `sdkKey`. Throwing models a transient transport
    /// failure (the SDK resolves `ready()` degraded on a thrown error rather than rethrowing).
    func load(sdkKey: String) async throws
}

/// Production default loader used by the public ``ConvertSDK`` initializers until the real
/// `URLSession`-backed fetch arrives in Story 2.3.
///
/// A no-op success so the public `init(configuration:)` works without a network: `load`
/// returns immediately, the SDK then signals config present, and `ready()` resolves. Story
/// 2.3 swaps in the real adapter.
public struct StubConfigLoader: ConfigLoader {
    /// Creates the no-op loader.
    public init() {}

    /// No-op success. Story 2.3 performs the real config fetch here.
    public func load(sdkKey: String) async throws {
        // Story 2.3: real config fetch. No-op success in Story 2.2.
    }
}
