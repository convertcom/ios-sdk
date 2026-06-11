// ConvertError.swift
// The single error type thrown across the Convert iOS SDK (AOD-6).
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// The sole error type thrown by the SDK (AOD-6 — one thrown type, never bare `Error`).
///
/// `errorDescription` follows the UX-DR18 voice: *what happened, then an actionable hint*.
/// Messages never reduce to a bare code or the lone word "error".
public enum ConvertError: LocalizedError, Sendable {
    /// The SDK configuration struct held invalid field values; the string describes which.
    case invalidConfiguration(String)
    /// The provided SDK key is structurally invalid; the string describes how.
    case invalidSdkKey(String)

    /// Human-readable, actionable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(detail):
            return "Invalid SDK configuration: \(detail). Verify the configuration struct fields."
        case let .invalidSdkKey(detail):
            return "Structurally invalid SDK key: \(detail). Verify the key in your Convert dashboard."
        }
    }
}
