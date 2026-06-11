// Tests/ConvertSDKCoreTests/Models/GoalDataKeyTests.swift
import Testing
import ConvertSDKCore

@Suite("GoalDataKey")
struct GoalDataKeyTests {
    // One parameterized body covers every case's wire mapping instead of eight
    // near-identical assertion lines — keeps new-duplicated-lines density under the
    // SonarQube gate. The explicit `[(GoalDataKey, String)]` element type keeps the
    // type-checker off the "expression too complex" path an untyped tuple-literal
    // array would otherwise trigger. Each pair is (case, exact JS wire rawValue)
    // verified against types.gen.ts — note there is NO `value` case.
    static let wireMappings: [(GoalDataKey, String)] = [
        (.amount, "amount"),
        (.productsCount, "productsCount"),
        (.transactionId, "transactionId"),
        (.customDimension1, "customDimension1"),
        (.customDimension2, "customDimension2"),
        (.customDimension3, "customDimension3"),
        (.customDimension4, "customDimension4"),
        (.customDimension5, "customDimension5")
    ]

    @Test("GoalDataKey enumerates exactly eight cases")
    func caseCount() {
        #expect(GoalDataKey.allCases.count == 8)
    }

    @Test("GoalDataKey rawValue matches its JS wire string", arguments: wireMappings)
    func rawValueMatchesWire(key: GoalDataKey, wire: String) {
        #expect(key.rawValue == wire, "expected \(wire), got \(key.rawValue)")
    }
}
