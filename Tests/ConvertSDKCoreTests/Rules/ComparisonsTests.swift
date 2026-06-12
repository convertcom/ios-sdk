// Tests/ConvertSDKCoreTests/Rules/ComparisonsTests.swift
// Operator-dispatch PARITY SUITE for `Comparisons.evaluate(...)` (Epic 3 / Story 3 —
// audience / location rule evaluation).
//
// RED phase (TDD): `Comparisons` does NOT exist yet (Sources/ConvertSDKCore/Rules/
// Comparisons.swift is unwritten). This file MUST fail to compile against the missing
// `Comparisons` symbol — that is the expected, correct RED state. The vectors below define
// the contract the to-be-built implementation has to satisfy.
//
// GROUND TRUTH: every expected value encodes the LIVE JavaScript SDK behavior verified
// directly against `javascript-sdk/packages/utils/src/comparisons.ts` (the authoritative
// parity reference), NOT the story's terser operator table. The seven LOSSY deltas the
// story's table omits are each pinned by at least one vector here:
//   1. `equals`/`equalsNumber`/`matches` are CASE-INSENSITIVE (lowercase both, line 37-39),
//      and `equalsNumber`/`matches` alias `equals` (string equals, NOT numeric — line 42-43).
//   2. `contains` is CASE-INSENSITIVE, `value` is the HAYSTACK / `testAgainst` is the NEEDLE,
//      and empty/whitespace-only `testAgainst` → true (line 78-86).
//   3. `startsWith`/`endsWith` are CASE-INSENSITIVE (lowercase both, line 122-140).
//   4. `less`/`lessEqual` are TYPE-GUARDED: if either side is non-numeric → false
//      (line 52-54, 65-67); otherwise numeric `<` / `<=`.
//   5. `regexMatches` is CASE-INSENSITIVE (JS `'i'` flag, line 150); invalid pattern → false.
//   6. `isIn` is ASYMMETRIC: `value` side NOT lowercased (line 95-99), `testAgainst` side
//      lowercased (line 106-108). So `isIn("B","A|B|C")` → false (candidate "B" stays
//      uppercase; allowed=["a","b","c"]); `isIn("b","A|B|C")` → true.
//   7. `exists` treats EMPTY STRING as ABSENT (`value !== ''`, line 159); `not_exists` /
//      `doesNotExist` are aliases of each other (line 163-173) and treat "" as absent too.
// Negation inverts the result of ALL operators (`_returnNegationCheck`, line 175-184).
// Unknown operator → false (fail-closed) + a logged WARN (rule-manager 362-366).
//
// SonarQube `new_duplicated_lines_density` (3% gate): ALL operator coverage rides ONE
// parameterized @Test over a single `operatorCases` table — never one @Test per operator,
// which would be near-identical duplicated bodies. The only separate @Test is the WARN
// assertion, which needs a named logger to inspect and so cannot live in the value-only table.

import Foundation
import Testing
@testable import ConvertSDKCore

@Suite("Comparisons")
struct ComparisonsTests {

    /// One operator-dispatch vector. A pure value type so swift-testing can pass it through
    /// `arguments:`. `description` is surfaced in the `#expect` message for failure triage.
    struct OperatorCase: Sendable {
        let matchType: String
        let value: String?
        let testAgainst: String?
        let negated: Bool
        let expected: Bool
        let description: String
    }

    /// Every vector encodes LIVE-JS-verified behavior (see header). Covers all 13 wire strings
    /// for dispatch plus each JS-truth edge case, with negation variants in-table.
    static let operatorCases: [OperatorCase] = [
        // --- equals: case-INSENSITIVE string equality (lowercase both) ---
        OperatorCase(matchType: "equals", value: "Foo", testAgainst: "foo", negated: false,
                     expected: true, description: "equals is case-insensitive (Foo == foo)"),
        OperatorCase(matchType: "equals", value: "foo", testAgainst: "foo", negated: false,
                     expected: true, description: "equals exact match"),
        OperatorCase(matchType: "equals", value: "foo", testAgainst: "bar", negated: false,
                     expected: false, description: "equals mismatch"),
        OperatorCase(matchType: "equals", value: "foo", testAgainst: "foo", negated: true,
                     expected: false, description: "equals negated inverts a true match"),
        OperatorCase(matchType: "equals", value: "foo", testAgainst: "bar", negated: true,
                     expected: true, description: "equals negated inverts a false match"),

        // --- equalsNumber: aliases equals (STRING equals, not numeric) ---
        OperatorCase(matchType: "equalsNumber", value: "42", testAgainst: "42", negated: false,
                     expected: true, description: "equalsNumber aliases equals: 42 == 42 as string"),
        OperatorCase(matchType: "equalsNumber", value: "Foo", testAgainst: "foo", negated: false,
                     expected: true, description: "equalsNumber is the equals path (case-insensitive)"),

        // --- matches: aliases equals (STRING equals) ---
        OperatorCase(matchType: "matches", value: "abc", testAgainst: "abc", negated: false,
                     expected: true, description: "matches aliases equals: abc == abc"),
        OperatorCase(matchType: "matches", value: "abc", testAgainst: "abd", negated: false,
                     expected: false, description: "matches aliases equals: abc != abd"),

        // --- less: numeric type-guard; non-numeric either side → false ---
        OperatorCase(matchType: "less", value: "3", testAgainst: "5", negated: false,
                     expected: true, description: "less numeric: 3 < 5"),
        OperatorCase(matchType: "less", value: "5", testAgainst: "3", negated: false,
                     expected: false, description: "less numeric: 5 < 3 is false"),
        OperatorCase(matchType: "less", value: "abc", testAgainst: "5", negated: false,
                     expected: false, description: "less type-guard: non-numeric value → false"),
        OperatorCase(matchType: "less", value: "3", testAgainst: "xyz", negated: false,
                     expected: false, description: "less type-guard: non-numeric testAgainst → false"),

        // --- lessEqual: numeric type-guard; boundary inclusive ---
        OperatorCase(matchType: "lessEqual", value: "5", testAgainst: "5", negated: false,
                     expected: true, description: "lessEqual boundary: 5 <= 5"),
        OperatorCase(matchType: "lessEqual", value: "6", testAgainst: "5", negated: false,
                     expected: false, description: "lessEqual: 6 <= 5 is false"),
        OperatorCase(matchType: "lessEqual", value: "abc", testAgainst: "5", negated: false,
                     expected: false, description: "lessEqual type-guard: non-numeric value → false"),

        // --- contains: case-INSENSITIVE; value=HAYSTACK, testAgainst=NEEDLE; empty needle → true ---
        OperatorCase(matchType: "contains", value: "Hello", testAgainst: "ELL", negated: false,
                     expected: true, description: "contains case-insensitive: Hello contains ELL"),
        OperatorCase(matchType: "contains", value: "Hello", testAgainst: "xyz", negated: false,
                     expected: false, description: "contains: Hello does not contain xyz"),
        OperatorCase(matchType: "contains", value: "anything", testAgainst: "", negated: false,
                     expected: true, description: "contains empty needle → true"),
        OperatorCase(matchType: "contains", value: "anything", testAgainst: "   ", negated: false,
                     expected: true, description: "contains whitespace-only needle → true"),

        // --- isIn: ASYMMETRIC — value side NOT lowercased, testAgainst side lowercased ---
        OperatorCase(matchType: "isIn", value: "b", testAgainst: "A|B|C", negated: false,
                     expected: true, description: "isIn: lowercase candidate b matches lowercased allowed"),
        OperatorCase(matchType: "isIn", value: "D", testAgainst: "A|B|C", negated: false,
                     expected: false, description: "isIn: D not in A|B|C"),
        OperatorCase(matchType: "isIn", value: "B", testAgainst: "A|B|C", negated: false,
                     expected: false, description: "isIn asymmetry: value B stays uppercase vs allowed [a,b,c]"),
        OperatorCase(matchType: "isIn", value: "", testAgainst: "a|b|", negated: false,
                     expected: true, description: "isIn empty value matches empty trailing segment (JS split parity)"),
        OperatorCase(matchType: "isIn", value: "", testAgainst: "a|b", negated: false,
                     expected: false, description: "isIn empty value no match when no empty segment"),
        OperatorCase(matchType: "isIn", value: nil, testAgainst: "a|b|", negated: false,
                     expected: false, description: "isIn nil value (absent key) never matches an empty segment (JS)"),

        // --- startsWith / endsWith: case-INSENSITIVE ---
        OperatorCase(matchType: "startsWith", value: "Hello", testAgainst: "HE", negated: false,
                     expected: true, description: "startsWith case-insensitive: Hello starts HE"),
        OperatorCase(matchType: "startsWith", value: "Hello", testAgainst: "lo", negated: false,
                     expected: false, description: "startsWith: Hello does not start with lo"),
        OperatorCase(matchType: "endsWith", value: "Hello", testAgainst: "LO", negated: false,
                     expected: true, description: "endsWith case-insensitive: Hello ends LO"),
        OperatorCase(matchType: "endsWith", value: "Hello", testAgainst: "he", negated: false,
                     expected: false, description: "endsWith: Hello does not end with he"),

        // --- regexMatches: case-INSENSITIVE ('i' flag); invalid pattern → false ---
        OperatorCase(matchType: "regexMatches", value: "ABC", testAgainst: "^a", negated: false,
                     expected: true, description: "regexMatches case-insensitive: ABC matches ^a"),
        OperatorCase(matchType: "regexMatches", value: "ABC", testAgainst: "^z", negated: false,
                     expected: false, description: "regexMatches: ABC does not match ^z"),
        OperatorCase(matchType: "regexMatches", value: "ABC", testAgainst: "[", negated: false,
                     expected: false, description: "regexMatches invalid pattern → false"),

        // --- exists: EMPTY STRING is ABSENT ---
        OperatorCase(matchType: "exists", value: "x", testAgainst: nil, negated: false,
                     expected: true, description: "exists: non-empty value present"),
        OperatorCase(matchType: "exists", value: nil, testAgainst: nil, negated: false,
                     expected: false, description: "exists: nil value absent"),
        OperatorCase(matchType: "exists", value: "", testAgainst: nil, negated: false,
                     expected: false, description: "exists: empty string counts as absent"),
        OperatorCase(matchType: "exists", value: nil, testAgainst: nil, negated: true,
                     expected: true, description: "exists negated: nil → false → inverted to true"),

        // --- not_exists / doesNotExist: aliases; EMPTY STRING is ABSENT ---
        OperatorCase(matchType: "not_exists", value: nil, testAgainst: nil, negated: false,
                     expected: true, description: "not_exists: nil value is absent → true"),
        OperatorCase(matchType: "not_exists", value: "", testAgainst: nil, negated: false,
                     expected: true, description: "not_exists: empty string is absent → true"),
        OperatorCase(matchType: "not_exists", value: "x", testAgainst: nil, negated: false,
                     expected: false, description: "not_exists: present value → false"),
        OperatorCase(matchType: "doesNotExist", value: nil, testAgainst: nil, negated: false,
                     expected: true, description: "doesNotExist aliases not_exists: nil → true"),
        OperatorCase(matchType: "doesNotExist", value: "x", testAgainst: nil, negated: false,
                     expected: false, description: "doesNotExist: present value → false")
    ]

    @Test("operator dispatch", arguments: operatorCases)
    func operatorDispatch(_ caseUnderTest: OperatorCase) {
        let result = Comparisons.evaluate(
            matchType: caseUnderTest.matchType,
            value: caseUnderTest.value,
            testAgainst: caseUnderTest.testAgainst,
            negated: caseUnderTest.negated,
            logger: MockLogger()
        )
        #expect(
            result == caseUnderTest.expected,
            "\(caseUnderTest.description): got \(result), expected \(caseUnderTest.expected)"
        )
    }

    /// Unknown operator must fail closed (return false) AND emit a WARN. This needs a named
    /// logger to inspect the captured entries, so it cannot live in the value-only table above.
    @Test("unknown operator returns false and logs WARN")
    func unknownOperatorFailsClosedWithWarn() {
        let logger = MockLogger()
        let result = Comparisons.evaluate(
            matchType: "unknownOp",
            value: "x",
            testAgainst: "x",
            negated: false,
            logger: logger
        )
        #expect(result == false, "unknown operator must fail closed (false)")
        #expect(
            logger.entries().contains { $0.level == .warn },
            "unknown operator must emit a WARN log entry"
        )
    }
}
