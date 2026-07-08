// ToLoggable.swift
// Redaction contract for log output in the Convert iOS SDK.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

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

/// Renders a single SDK-key token as `sk_…<last4-of-key-material>`, or fully-redacted `sk_…`
/// when the key material (everything after the `sk_` prefix) is 4 characters or fewer.
///
/// The suffix is taken from the key material — NOT the full token — so the `sk_` prefix can
/// never count toward the exposed window (which would leak the `_` separator and shrink the
/// real redaction for short keys).
private func maskedKey(for token: String) -> String {
    let material = String(token.dropFirst(3)) // drop the "sk_" prefix
    guard material.count > 4 else {
        return "sk_" + redactionEllipsis
    }
    return "sk_" + redactionEllipsis + String(material.suffix(4))
}

/// Replaces the value of secret-bearing query params (`sdkKeySecret`, `sdkKey`) with `…`, and
/// strips `debug_token=<value>` (qs-02 IOS-1, AC3) ENTIRELY — param name included, not just the
/// value — so a redacted log line never carries the `debug_token=` substring at all. `sdkKeySecret`
/// / `sdkKey` keep their param name (only the value is masked); `debug_token` does not, because
/// (unlike a rotatable API secret) the token IS the QA session identifier and its param name
/// alone is enough to fingerprint a debug session in log aggregation, so this leaves nothing
/// behind (see `DebugTokenRedactionTests.warnLineDoesNotLeakDebugToken`).
///
/// One alternation (not two independently-run regexes) so future secret-param additions stay a
/// single-pattern extension; the two alternatives are told apart per-match via the presence /
/// absence of capture group 1, which only the `sdkKeySecret|sdkKey` branch populates.
private func stripSecretQueryParams(from value: String) -> String {
    // Match `<param>=<value>` up to the next `&`, `#`, whitespace, or end of string. Group 1
    // captures the masked-param-name branch only; the `debug_token` branch has no capture group,
    // so `match.range(at: 1)` is `NSNotFound` for it (the per-match discriminator below).
    guard let regex = try? NSRegularExpression(
        pattern: "(?:(sdkKeySecret|sdkKey)=[^&#\\s]*)|debug_token=[^&#\\s]*"
    ) else {
        return value
    }

    let fullRange = NSRange(location: 0, length: (value as NSString).length)
    let matches = regex.matches(in: value, range: fullRange)

    // Rebuild back-to-front so earlier ranges stay valid as we splice in replacements.
    var result = value
    for match in matches.reversed() {
        guard let matchRange = Range(match.range, in: result) else { continue }
        if let paramNameRange = Range(match.range(at: 1), in: result) {
            // sdkKeySecret / sdkKey — keep the param name, redact only the value.
            let paramName = String(result[paramNameRange])
            result.replaceSubrange(matchRange, with: "\(paramName)=\(redactionEllipsis)")
        } else {
            // debug_token — strip the whole `debug_token=<value>` pair, name included.
            result.replaceSubrange(matchRange, with: redactionEllipsis)
        }
    }
    return result
}
