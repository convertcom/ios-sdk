// Tests/ConvertSDKCoreTests/ToLoggableTests.swift
import Testing
import ConvertSDKCore

/// Verifies the `toLoggable` redaction contract (NFR6): SDK keys are masked so at most the
/// last four characters of the key material survive, and secret-bearing query params are
/// stripped. Short keys must be fully redacted — the `sk_` prefix must never count toward the
/// exposed window.
@Suite("ToLoggable redaction")
struct ToLoggableTests {
    /// A masking expectation: the masked output must contain `allowed` and must not contain
    /// `forbidden`. Modeled as a struct (not a 3-tuple) to satisfy the `large_tuple` lint rule
    /// while still driving one parameterized body — keeping new-duplicated-lines under the
    /// SonarQube gate.
    struct RedactionCase: Sendable {
        let input: String
        let allowed: String
        let forbidden: String
    }

    static let keyCases: [RedactionCase] = [
        // Long key: only the trailing 4 of the key material ("1234") may remain; the leading
        // key material ("live_abcd") must be gone.
        RedactionCase(input: "token sk_live_abcd1234 used", allowed: "sk_\u{2026}1234", forbidden: "live_abcd"),
        // Short key (material "abc", < 4 chars): fully redacted — the material must not leak,
        // and the prefix underscore must not be smuggled into the exposed window.
        RedactionCase(input: "token sk_abc used", allowed: "sk_\u{2026}", forbidden: "abc")
    ]

    @Test("SDK keys are masked, short keys fully redacted", arguments: keyCases)
    func masksKeys(_ testCase: RedactionCase) {
        let masked = toLoggable(testCase.input)
        #expect(masked.contains(testCase.allowed))
        #expect(!masked.contains(testCase.forbidden))
    }

    @Test("secret query params are stripped from logged URLs")
    func stripsSecretQueryParams() {
        let masked = toLoggable("GET https://api.convert.com/v1/config?sdkKeySecret=supersecret&x=1")
        #expect(!masked.contains("supersecret"))
        #expect(masked.contains("x=1"))
    }
}
