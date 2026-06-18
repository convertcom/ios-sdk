// NoopLogger.swift
// A no-op `Logger` implementation.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// A ``Logger`` that discards every line.
///
/// The production default sink for components that REQUIRE a non-`nil` ``Logger`` but for which
/// no destination logger exists yet — currently the `ConfigFetchService` the public
/// ``ConvertSDK`` initializers build. A real `OSLog`-backed adapter is a later story's concern;
/// this story only needs the fetch service to have a `Logger` it can call. The redaction
/// contract (NFR6) is enforced INSIDE `ConfigFetchService` via `toLoggable` before any line
/// reaches a logger, so routing those (already-redacted) WARNs into a sink that drops them is
/// safe — nothing sensitive is retained because nothing is retained at all.
///
/// A `Sendable` value type with no stored state, so it crosses actor boundaries with no
/// suppression and can be shared freely.
public struct NoopLogger: Logger {
    /// Creates the no-op logger.
    public init() {}

    /// Discards the line. Intentionally empty — see the type doc.
    public func log(level: LogLevel, type: String, method: String, message: String) {
        // No-op: every log line is discarded.
    }
}
