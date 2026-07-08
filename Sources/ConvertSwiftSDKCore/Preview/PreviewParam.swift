// PreviewParam.swift
// Pure parser for the `convert_preview={experienceId}.{variationId}` link param (qs-02
// Experiment Preview, contract §2 / AC9). Foundation-only — part of the pure-logic
// ConvertSwiftSDKCore target.

import Foundation

/// Parses the `convert_preview` link param used to seed experiment previews.
public enum PreviewParam {

    /// Parses `convert_preview={experienceId}.{variationId}` — dot-separated numeric-id
    /// strings, mirroring the web force-param format `_conv_eforce={expId}.{varId}`.
    ///
    /// - Parameter value: the raw param value, e.g. `"123.456"`.
    /// - Returns: the `(experienceId, variationId)` pair, or `nil` if `value` is not exactly
    ///   two non-empty, all-digit components separated by a single `.`.
    public static func parse(_ value: String) -> (experienceId: String, variationId: String)? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2 else {
            return nil
        }

        let experienceId = components[0]
        let variationId = components[1]

        guard isNumericID(experienceId), isNumericID(variationId) else {
            return nil
        }

        return (experienceId: String(experienceId), variationId: String(variationId))
    }

    /// `true` when `component` is non-empty and every character is an ASCII decimal digit
    /// (`0`-`9`).
    private static func isNumericID(_ component: Substring) -> Bool {
        !component.isEmpty && component.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
