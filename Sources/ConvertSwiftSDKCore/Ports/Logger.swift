// Logger.swift
// Port: structured logging sink.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// Structured logging sink for the SDK.
///
/// The four-parameter form enforces the `[LEVEL] {Type}.{method}: {message}` log-line
/// format (UX-DR19): adapters concatenate these fields into the final string. The port
/// deliberately never accepts a single pre-formatted string, so the line format has one
/// owner (the adapter) and cannot drift across call sites. The `level` parameter is the
/// existing ``LogLevel`` type.
public protocol Logger: Sendable {
    /// Emits one structured log line composed from the severity, the originating type and
    /// method, and the message.
    func log(level: LogLevel, type: String, method: String, message: String)
}
