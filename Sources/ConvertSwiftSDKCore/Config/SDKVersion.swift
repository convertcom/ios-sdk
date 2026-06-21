// SDKVersion.swift
// Single source of truth for the SDK version string embedded in the ConvertAgent User-Agent header.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// Single source of truth for the Convert iOS SDK version string.
///
/// ``current`` is the canonical semver value (three dot-separated integer components) embedded in
/// the `ConvertAgent` User-Agent header. Bump it here — and only here — when releasing a new SDK
/// version so every consumer stays in lockstep.
public enum SDKVersion {
    /// The current SDK version (semver: `MAJOR.MINOR.PATCH`).
    public static let current = "1.0.0"
}
