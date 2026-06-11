// ToLoggable.swift
// Redaction contract for log output in the Convert iOS SDK.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Redacts secrets from a string before it is handed to a logger.
///
/// This is the **frozen signature** for the SDK redaction contract. The full structural
/// redaction (recursively walking logged values, headers, and structured payloads) is
/// completed in **Story 2.3**; this implementation ships the two minimum behaviors the
/// contract guarantees today:
///
/// 1. **SDK key masking** — any `sk_<alphanumerics/underscores>` token is collapsed to
///    `sk_…<last4>`, exposing only the final four characters of the full key.
/// 2. **Secret query-param stripping** — `sdkKeySecret=<value>` and `sdkKey=<value>`
///    query parameters in logged URLs have their value replaced with `…`.
///
/// It deliberately does **not** serialize any OpenAPI-generated model through that model's
/// own `Codable` codec — it operates purely on the `String` form passed in.
///
/// - Parameter value: The raw string about to be logged.
/// - Returns: The string with SDK keys and secret query-param values redacted.
public func toLoggable(_ value: String) -> String {
    let keyMasked = maskSDKKeys(in: value)
    return stripSecretQueryParams(from: keyMasked)
}

/// The ellipsis used in all redaction placeholders.
private let redactionEllipsis = "\u{2026}" // …

/// Replaces every `sk_[A-Za-z0-9_]+` token with `sk_…<last4>` of that token.
private func maskSDKKeys(in value: String) -> String {
    // `try?` (not `try!`) keeps this force-unwrap / force-try free. The pattern is a
    // compile-time-constant literal, so construction never actually fails; on the
    // impossible failure path we return the input unchanged rather than crash.
    guard let regex = try? NSRegularExpression(pattern: "sk_[A-Za-z0-9_]+") else {
        return value
    }

    let nsValue = value as NSString
    let fullRange = NSRange(location: 0, length: nsValue.length)
    let matches = regex.matches(in: value, range: fullRange)

    // Rebuild back-to-front so earlier ranges stay valid as we splice in replacements.
    var result = value
    for match in matches.reversed() {
        guard let swiftRange = Range(match.range, in: result) else { continue }
        let token = String(result[swiftRange])
        result.replaceSubrange(swiftRange, with: maskedKey(for: token))
    }
    return result
}

/// Renders a single SDK-key token as `sk_…<last4>` (or `sk_…` if it is shorter than 4 chars).
private func maskedKey(for token: String) -> String {
    let last4 = String(token.suffix(4))
    return "sk_" + redactionEllipsis + last4
}

/// Replaces the value of secret-bearing query params (`sdkKeySecret`, `sdkKey`) with `…`.
private func stripSecretQueryParams(from value: String) -> String {
    // Match `<param>=<value>` up to the next `&`, `#`, whitespace, or end of string.
    guard let regex = try? NSRegularExpression(
        pattern: "(sdkKeySecret|sdkKey)=[^&#\\s]*"
    ) else {
        return value
    }

    let nsValue = value as NSString
    let fullRange = NSRange(location: 0, length: nsValue.length)
    let template = "$1=" + redactionEllipsis
    return regex.stringByReplacingMatches(
        in: value,
        range: fullRange,
        withTemplate: template
    )
}
