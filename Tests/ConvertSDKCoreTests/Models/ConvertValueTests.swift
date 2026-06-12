// Tests/ConvertSDKCoreTests/Models/ConvertValueTests.swift
// RED-phase contract for `ConvertValue` (Epic 3 / Story 1). `ConvertValue` is `public`, so a
// plain `import` reaches it (matching `GoalDataKeyTests`); the type does not exist yet, so this
// suite is EXPECTED to fail to compile (the correct RED outcome).
//
// CONTRACT under test:
//   * `ConvertValue(any:)` coerces `Any` → the matching case, returning `nil` for unsupported
//     types. The Bool/Int boundary is load-bearing: `true` must become `.bool(true)` (NOT
//     `.int(1)`), `30` must become `.int(30)`, `3.5` → `.double(3.5)`, `"x"` → `.string("x")`,
//     and a nested dictionary → `nil`.
//   * `anyValue` reconstructs the underlying value, so `.int(30).anyValue as? Int == 30`, etc.
import Foundation
import Testing
import ConvertSDKCore

@Suite("ConvertValue")
struct ConvertValueTests {
    // MARK: Coercion sweep (parameterized)

    /// One coercion case. The input is boxed behind a `@Sendable () -> Any` thunk so the case
    /// stays `Sendable` (swift-testing's `arguments:` requires `Sendable` elements) while still
    /// feeding a heterogeneous `Any` value through `init?(any:)`. A named struct (not a tuple)
    /// keeps the `large_tuple` lint rule satisfied. `expected == nil` asserts the unsupported path.
    struct CoercionCase: Sendable {
        let label: String
        let makeInput: @Sendable () -> Any
        let expected: ConvertValue?
    }

    static let coercionCases: [CoercionCase] = [
        CoercionCase(label: "Bool true → .bool", makeInput: { true }, expected: .bool(true)),
        CoercionCase(label: "Int 30 → .int", makeInput: { 30 }, expected: .int(30)),
        CoercionCase(label: "Double 3.5 → .double", makeInput: { 3.5 }, expected: .double(3.5)),
        CoercionCase(label: "String x → .string", makeInput: { "x" }, expected: .string("x")),
        CoercionCase(label: "nested dict → nil", makeInput: { ["nested": 1] }, expected: nil)
    ]

    @Test("ConvertValue(any:) coerces each supported type and rejects the rest", arguments: coercionCases)
    func coercesFromAny(testCase: CoercionCase) {
        #expect(
            ConvertValue(any: testCase.makeInput()) == testCase.expected,
            "\(testCase.label): coercion result did not match the expected case"
        )
    }

    // MARK: Round-trip (parameterized)

    /// One round-trip case: a `ConvertValue` and a `@Sendable` predicate asserting its
    /// `anyValue` reconstructs to the right dynamic type AND value. Boxing the check in a thunk
    /// lets one parameterized body cover all four cases without re-spelling the `as?` ladder.
    struct RoundTripCase: Sendable {
        let label: String
        let value: ConvertValue
        let check: @Sendable (Any) -> Bool
    }

    static let roundTripCases: [RoundTripCase] = [
        RoundTripCase(label: ".string", value: .string("hello"), check: { ($0 as? String) == "hello" }),
        RoundTripCase(label: ".int", value: .int(30), check: { ($0 as? Int) == 30 }),
        RoundTripCase(label: ".double", value: .double(3.5), check: { ($0 as? Double) == 3.5 }),
        RoundTripCase(label: ".bool", value: .bool(true), check: { ($0 as? Bool) == true })
    ]

    @Test("anyValue reconstructs the underlying value for each case", arguments: roundTripCases)
    func anyValueRoundTrips(testCase: RoundTripCase) {
        #expect(
            testCase.check(testCase.value.anyValue),
            "\(testCase.label): anyValue did not reconstruct the expected dynamic type/value"
        )
    }
}
