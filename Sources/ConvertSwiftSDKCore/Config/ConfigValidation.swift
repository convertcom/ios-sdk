// ConfigValidation.swift
// SDK-internal configuration validation (Epic 2 / Story 2).
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// SDK-internal validation for the two configuration entry points.
///
/// `internal` by design: configuration validation is an implementation detail, not public
/// API. Both overloads use typed throws (`throws(ConvertError)`) so callers handle exactly
/// the one SDK error type (AOD-6).
internal enum ConfigValidation {
    /// Rejects a blank or whitespace-only ``ConvertConfiguration/sdkKey``; accepts any
    /// non-empty key silently.
    /// - Throws: ``ConvertError/invalidConfiguration(_:)`` when the trimmed key is empty.
    static func validate(_ config: ConvertConfiguration) throws(ConvertError) {
        let trimmed = config.sdkKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConvertError.invalidConfiguration(
                "SDK key must not be empty. Provide a non-empty SDK key from your Convert project."
            )
        }
    }

    /// Rejects an empty pre-fetched config payload; accepts any non-empty `Data` silently.
    /// The real structural decode lands in Story 2.3 — for now this only guards emptiness.
    /// - Throws: ``ConvertError/invalidConfiguration(_:)`` when `data` is empty.
    static func validate(_ data: Data) throws(ConvertError) {
        guard !data.isEmpty else {
            throw ConvertError.invalidConfiguration(
                "Pre-fetched config data is empty. Provide non-empty project config Data, "
                    + "or initialize with an SDK key instead."
            )
        }
        // Story 2.3 adds the real structural decode here.
    }
}
