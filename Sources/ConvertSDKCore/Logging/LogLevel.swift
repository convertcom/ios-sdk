// LogLevel.swift
// Severity-ordered log levels for the Convert iOS SDK.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Log severity levels, ordered from most verbose (`trace`) to fully muted (`silent`).
///
/// `Comparable` compares by *severity*: `trace < debug < info < warn < error < silent`.
/// A logger configured at a given level emits messages whose level is `>=` the configured
/// threshold. The default ship level is ``warn`` — production builds suppress `trace`,
/// `debug`, and `info` unless explicitly lowered.
public enum LogLevel: String, CaseIterable, Comparable, Sendable {
    case trace
    case debug
    case info
    case warn
    case error
    case silent

    /// Ascending severity rank. Lower means more verbose; higher means more severe/quiet.
    /// Defined via an exhaustive `switch` (no `allCases.firstIndex(of:)!`) so the
    /// comparison never force-unwraps — `force_unwrapping` is an enabled lint rule.
    private var severityRank: Int {
        switch self {
        case .trace: return 0
        case .debug: return 1
        case .info: return 2
        case .warn: return 3
        case .error: return 4
        case .silent: return 5
        }
    }

    /// Orders two levels by ascending severity (`trace` is lowest, `silent` is highest).
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.severityRank < rhs.severityRank
    }
}
