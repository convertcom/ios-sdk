// Tests/ConvertSwiftSDKCoreTests/Models/GoalDataKeyTests.swift
import Foundation
import Testing
import ConvertSwiftSDKCore

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

/// Pins the wire contract of `GoalDataValue` and `GoalData.toEntries()`.
///
/// `GoalDataValue` and `GoalDataEntry` are NOT `Equatable` (the frozen source conforms only
/// to `Codable, Sendable`), so every equality check below is **structural**: values are
/// compared by encoding to their bare JSON token and comparing the strings, and array
/// elements are looked up by their `"key"` field after `JSONSerialization`. Nothing here uses
/// `==` on the DTOs, and the frozen DTOs are NOT extended with `Equatable`.
@Suite("GoalDataValue & GoalData.toEntries")
struct GoalDataValueTests {
    // A reusable two-key goal-data map. Built once here so the round-trip, array-shape, and
    // serialization tests share one construction instead of re-inlining the dictionary
    // literal in each test body (SonarQube token-based duplication guard).
    static func makeGoalData() -> GoalData {
        [.amount: .double(9.99), .transactionId: .string("txn-001")]
    }

    /// The backend-shaped array form of `makeGoalData()`, used as the round-trip input.
    static let backendArrayJSON = """
    [{"key":"amount","value":9.99},{"key":"transactionId","value":"txn-001"}]
    """

    // AC3 — one parameterized body proves each `GoalDataValue` case encodes to its BARE JSON
    // token (no object wrapper). Crucially `.double(9.99)` must be the number `9.99`, never the
    // string `"9.99"`. Element type is spelled out so the type-checker stays off the
    // "expression too complex" path the untyped tuple-literal array would otherwise trigger.
    static let valueTokens: [(GoalDataValue, String)] = [
        (.double(9.99), "9.99"),
        (.string("txn-001"), "\"txn-001\""),
        (.strings(["a", "b"]), "[\"a\",\"b\"]")
    ]

    @Test("GoalDataValue encodes to its bare JSON token", arguments: valueTokens)
    func encodesBareToken(value: GoalDataValue, token: String) {
        #expect(
            CodableTestHelpers.encodeJSONString(value) == token,
            "expected bare JSON token \(token)"
        )
    }

    // AC4 — `toEntries()` maps each (key, value) pair to a `GoalDataEntry(key:value:)`. Order is
    // undefined (a dictionary has no order), so the resulting entry for each key is located and
    // its value asserted STRUCTURALLY by encoding that entry's `value` to its bare JSON token
    // (the DTOs are not Equatable). This is the RED target: `GoalData.toEntries()` does not yet
    // exist, so this test will not compile until GREEN adds it.
    @Test("toEntries maps each dictionary pair to a GoalDataEntry")
    func toEntriesMapsPairs() {
        let entries = Self.makeGoalData().toEntries()
        #expect(entries.count == 2)

        let amount = entries.first { $0.key == .amount }
        let transaction = entries.first { $0.key == .transactionId }
        #expect(amount.map { CodableTestHelpers.encodeJSONString($0.value) } == "9.99")
        #expect(
            transaction.map { CodableTestHelpers.encodeJSONString($0.value) } == "\"txn-001\""
        )
    }

    // AC4 — the encoded `[GoalDataEntry]` is a JSON ARRAY of `{key, value}` objects (NOT a flat
    // `{"amount":9.99}` map). Decoded via `JSONSerialization` and inspected element-by-element:
    // the element whose `"key"` is `"amount"` carries the number `9.99`, and the `"transactionId"`
    // element carries the string `"txn-001"`.
    @Test("encoded toEntries is a JSON array of {key,value} objects")
    func toEntriesEncodesArrayOfPairs() throws {
        let entries = Self.makeGoalData().toEntries()
        guard let data = try? CodableTestHelpers.sortedKeysEncoder.encode(entries) else {
            Issue.record("[GoalDataEntry] failed to encode")
            return
        }
        let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(array?.count == 2)
        // Bind each element lookup to a typed `[String: Any]?` first; chaining
        // `.first {…}?["value"] as? T == …` directly inside `#expect` leaves the autoclosure
        // expression ambiguous for the type-checker.
        let amount = array?.first { $0["key"] as? String == "amount" }
        let transaction = array?.first { $0["key"] as? String == "transactionId" }
        #expect(amount?["value"] as? Double == 9.99)
        #expect(transaction?["value"] as? String == "txn-001")
    }

    // AC4 — bidirectional parity: a backend-shaped `[{"key":…,"value":…}]` payload decodes into
    // `[GoalDataEntry]` and re-encodes to a payload whose canonical (sorted-key) form equals the
    // canonical form of the input. Proves decode and encode are inverses over the array shape.
    @Test("backend-shaped goalData array round-trips to canonical-equal JSON")
    func toEntriesRoundTrips() throws {
        let input = Data(Self.backendArrayJSON.utf8)
        let decoded = try JSONDecoder().decode([GoalDataEntry].self, from: input)
        let reencoded = try CodableTestHelpers.sortedKeysEncoder.encode(decoded)
        #expect(try CodableTestHelpers.canonical(reencoded) == CodableTestHelpers.canonical(input))
    }
}
