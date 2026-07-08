// Tests/ConvertSwiftSDKCoreTests/Preview/PreviewParamTests.swift
// Pure-parse PARITY SUITE for `PreviewParam.parse(_:)` (qs-02 Experiment Preview — AC9).
//
// RED phase (TDD): `PreviewParam` does NOT exist yet (Sources/ConvertSwiftSDKCore/Preview/
// PreviewParam.swift is unwritten). This file MUST fail to compile against the missing
// `PreviewParam` symbol — that is the expected, correct RED state. The vectors below define
// the contract the to-be-built implementation has to satisfy.
//
// SPEC (qs-02-experiment-preview.md, contract §2 + AC9): the canonical link param is
// `convert_preview={experienceId}.{variationId}` — dot-separated NUMERIC-ID strings, mirroring
// the web force-param `_conv_eforce={expId}.{varId}`. `"123.456"` -> `(experienceId: "123",
// variationId: "456")`. Malformed input -> `nil`: no dot, empty side, non-numeric side, more
// than one dot, trailing/leading dot, empty string, whitespace-only.
//
// SonarQube `new_duplicated_lines_density` (3% gate): ALL parse coverage rides ONE
// parameterized @Test over a single `parseCases` table — never one @Test per malformed
// category, which would be near-identical duplicated bodies.
//
// NOTE: `PreviewParam.parse` returns a named tuple `(experienceId: String, variationId:
// String)?`, and Swift tuples are not `Equatable`, so `#expect(==)` cannot compare them
// directly. Each case's expectation is expressed as an optional `ParsedPair` (a local,
// `Equatable`, `Sendable` value type); the actual tuple result is mapped into a `ParsedPair`
// before comparison.

import Foundation
import Testing
@testable import ConvertSwiftSDKCore

@Suite("PreviewParam")
struct PreviewParamTests {

    /// Comparable stand-in for the `(experienceId: String, variationId: String)` tuple that
    /// `PreviewParam.parse` returns, since tuples are not `Equatable`.
    struct ParsedPair: Equatable, Sendable {
        let experienceId: String
        let variationId: String
    }

    /// One parse vector. A pure value type so swift-testing can pass it through `arguments:`.
    struct ParseCase: Sendable {
        let input: String
        let expected: ParsedPair?
        let description: String
    }

    /// Covers the valid canonical case plus every malformed category named in AC9 / contract §2.
    static let parseCases: [ParseCase] = [
        // --- valid: dot-separated numeric-id strings ---
        ParseCase(
            input: "123.456",
            expected: ParsedPair(experienceId: "123", variationId: "456"),
            description: "canonical numeric pair parses to (experienceId, variationId)"
        ),

        // --- no dot ---
        ParseCase(
            input: "123456",
            expected: nil,
            description: "no dot separator -> nil"
        ),

        // --- empty side ---
        ParseCase(
            input: ".456",
            expected: nil,
            description: "empty experienceId side (single leading dot) -> nil"
        ),
        ParseCase(
            input: "123.",
            expected: nil,
            description: "empty variationId side (single trailing dot) -> nil"
        ),

        // --- non-numeric side ---
        ParseCase(
            input: "abc.456",
            expected: nil,
            description: "non-numeric experienceId side -> nil"
        ),
        ParseCase(
            input: "123.abc",
            expected: nil,
            description: "non-numeric variationId side -> nil"
        ),

        // --- more than one dot (three non-empty components) ---
        ParseCase(
            input: "123.456.789",
            expected: nil,
            description: "more than one dot with non-empty components -> nil"
        ),

        // --- trailing/leading dot (extra dot producing an empty extra component) ---
        ParseCase(
            input: "123.456.",
            expected: nil,
            description: "trailing dot after a valid pair -> nil"
        ),
        ParseCase(
            input: ".123.456",
            expected: nil,
            description: "leading dot before a valid pair -> nil"
        ),

        // --- empty string ---
        ParseCase(
            input: "",
            expected: nil,
            description: "empty string -> nil"
        ),

        // --- whitespace-only ---
        ParseCase(
            input: "   ",
            expected: nil,
            description: "whitespace-only string -> nil"
        )
    ]

    @Test("parse", arguments: parseCases)
    func parse(_ caseUnderTest: ParseCase) {
        let result = PreviewParam.parse(caseUnderTest.input)
        let resultPair = result.map { ParsedPair(experienceId: $0.experienceId, variationId: $0.variationId) }
        let got = String(describing: resultPair)
        let want = String(describing: caseUnderTest.expected)
        #expect(resultPair == caseUnderTest.expected, "\(caseUnderTest.description): got \(got), expected \(want)")
    }
}
