// Tests/ConvertSwiftSDKCoreTests/ToLoggableTests.swift
import Testing
import ConvertSwiftSDKCore

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

    /// `debug_token` boundary-anchoring cases (qs-02 Fix 2): a lookalike param name is left
    /// untouched, while a real `debug_token=<value>` is fully stripped (name included) whether it
    /// sits right after `?`, right after `&`, or at the very start of the string with no leading
    /// `?`/`&` at all.
    static let debugTokenBoundaryCases: [RedactionCase] = [
        // Lookalike param `x_debug_token` must NOT be over-stripped — the whole pair survives
        // verbatim, and no ellipsis is introduced anywhere in the string.
        RedactionCase(
            input: "GET https://api.convert.com/v1/config?x_debug_token=secret&y=1",
            allowed: "x_debug_token=secret",
            forbidden: "\u{2026}"
        ),
        // Bare-start (no leading `?`/`&`): the real param is still fully stripped, name included.
        RedactionCase(input: "debug_token=secret&y=1", allowed: "y=1", forbidden: "debug_token="),
        // Bare-start: the token VALUE must not leak either (a miss here is a credential leak).
        RedactionCase(input: "debug_token=secret&y=1", allowed: "y=1", forbidden: "secret"),
        // `?`-prefixed: the real param is still fully stripped, name included.
        RedactionCase(
            input: "https://api.convert.com/v1/config?debug_token=secret&y=1",
            allowed: "y=1",
            forbidden: "debug_token="
        ),
        // `?`-prefixed: the token VALUE must not leak either.
        RedactionCase(
            input: "https://api.convert.com/v1/config?debug_token=secret&y=1",
            allowed: "y=1",
            forbidden: "secret"
        )
    ]

    @Test(
        "debug_token is boundary-anchored: lookalikes survive, real tokens are fully stripped",
        arguments: debugTokenBoundaryCases
    )
    func anchorsDebugTokenBoundary(_ testCase: RedactionCase) {
        let masked = toLoggable(testCase.input)
        #expect(masked.contains(testCase.allowed))
        #expect(!masked.contains(testCase.forbidden))
    }
}
