// Tests/ConvertSwiftSDKCoreTests/Rules/MutualExclusionGenericRegressionTests.swift
//
// RED-phase suite for IOS-2 (M2 unit, iOS mutual-exclusion qs-03) — AC7 ("generic-rule regression
// lock"): adding the JSON-sentinel `RuleAdapter.flatten(_ sentinelRuleTree: JSONValue)` overload (see
// the sibling `MutualExclusionRuleAdapterJSONFlattenTests.swift` for its assumed shape/rationale —
// not re-derived here) must NOT change how a GENERIC leaf resolves through the EXISTING typed path,
// and the NEW JSON-sentinel path must produce the SAME `RuleCondition`s the typed path already does
// for the SAME wire leaf — "reuse, do not fork, the OR/AND/OR_WHEN semantics" (qs-03 AC7 wording).
// Spec of record:
//   _bmad-output/planning-artifacts/2026-06-09-convert-ios-sdk/qs-03-mutual-exclusion-rule.md
// Task/plan: work/2026-07-15-ios-sdk-mutual-exclusion/workflow-state.yaml (task IOS-2, "v18s").
//
// ── Isolation rationale (per the IOS-2 dispatch) ──────────────────────────────────────────────────
// Kept as its OWN file, deliberately separate from `MutualExclusionRuleAdapterJSONFlattenTests.swift`
// (which proves a STATEFUL leaf survives ALONGSIDE a generic one) and from
// `MutualExclusionRuleManagerTests.swift` (which proves `RuleManager`'s resolver seam) — so a
// regression in the bit-identical generic-path contract shows up as its own isolated failure, not
// entangled with the new stateful-leaf assertions.
//
// This file depends on the SAME not-yet-existing symbol as its sibling —
// `RuleAdapter.flatten(_ sentinelRuleTree: JSONValue) -> [RuleGroup]` — and so MUST fail to COMPILE
// today ("type 'RuleAdapter' has no member 'flatten'" for a `JSONValue` argument), the expected,
// correct RED state; as with the sibling suites, this breaks `swift build`/`swift test` for the WHOLE
// `ConvertSwiftSDKCoreTests` target until GREEN lands (unavoidable in a single-SPM-module target).
//
// ── Method ─────────────────────────────────────────────────────────────────────────────────────────
// For each of 3 generic families (a text family via `city`, the `country` family, and the `bool`
// family via `is_desktop` — the exact three families the IOS-2 dispatch names), the SAME leaf JSON is
// decoded TWO ways: once through the EXISTING typed `Components.Schemas.RuleObjectAudience` decoder
// (`RuleAdapter.flatten(_ audience:)`), once through the NEW `JSONValue` decoder
// (`RuleAdapter.flatten(_ sentinelRuleTree:)`) — and the two `[RuleGroup]` results are asserted
// EQUAL. `RuleGroup`/`RuleCondition` are both `Equatable` (structural, synthesized), so this is a
// direct bit-identical comparison, not a field-by-field manual check that could itself drift.
//
// SonarQube `new_duplicated_lines_density` guard: ONE parameterized `@Test(arguments:)` drives all 3
// families from a single `genericLeafCases` table + two shared decode helpers — no per-family test
// function duplication.

import Foundation
import Testing
@testable import ConvertSwiftSDKCore

@Suite("RuleAdapter generic-rule regression lock: typed vs JSON-sentinel flatten — IOS-2 AC7 RED")
struct MutualExclusionGenericRegressionTests {

    /// One generic-family leaf JSON literal under test, reusing the EXACT shapes already proven
    /// end-to-end by `RuleAdapterTests` (city/`contains`, country/`equals`, is_desktop/`equals`) so
    /// this suite carries no risk of a fixture typo silently producing a false-negative "these agree"
    /// result.
    struct GenericLeafCase: Sendable {
        let description: String
        let leafJSON: String
    }

    static let genericLeafCases: [GenericLeafCase] = [
        GenericLeafCase(
            description: "text family (city, match_type contains)",
            leafJSON: #"{ "rule_type": "city", "value": "NY", "matching": { "match_type": "contains" } }"#
        ),
        GenericLeafCase(
            description: "country family (match_type equals)",
            leafJSON: #"{ "rule_type": "country", "value": "US", "matching": { "match_type": "equals" } }"#
        ),
        GenericLeafCase(
            description: "bool family (is_desktop, match_type equals)",
            leafJSON: #"{ "rule_type": "is_desktop", "value": true, "matching": { "match_type": "equals" } }"#
        )
    ]

    /// Decodes `leavesJSON` through the EXISTING typed `RuleObjectAudience` path (the same envelope
    /// `RuleAdapterTests.makeAudienceRules` uses).
    private func decodeTyped(orWhenLeaves leavesJSON: String) throws -> Components.Schemas.RuleObjectAudience {
        let envelope = """
        { "OR": [ { "AND": [ { "OR_WHEN": [ \(leavesJSON) ] } ] } ] }
        """
        return try JSONDecoder().decode(
            Components.Schemas.RuleObjectAudience.self,
            from: Data(envelope.utf8)
        )
    }

    /// Decodes the SAME `leavesJSON` through the NEW `JSONValue` sentinel path.
    private func decodeSentinelRuleTree(orWhenLeaves leavesJSON: String) throws -> JSONValue {
        let envelope = """
        { "OR": [ { "AND": [ { "OR_WHEN": [ \(leavesJSON) ] } ] } ] }
        """
        return try JSONDecoder().decode(JSONValue.self, from: Data(envelope.utf8))
    }

    /// AC7: for every generic family, the typed-path and JSON-sentinel-path flatten to EQUAL
    /// `[RuleGroup]` — the new JSON-walk must reuse, not fork, the per-leaf extraction and the
    /// OR/AND/OR_WHEN collapse.
    @Test(
        "typed-path and JSON-sentinel-path flatten produce bit-identical RuleGroups per generic family",
        arguments: genericLeafCases
    )
    func typedAndJSONPathsAgree(_ testCase: GenericLeafCase) throws {
        let typedGroups = RuleAdapter.flatten(try decodeTyped(orWhenLeaves: testCase.leafJSON))
        let jsonGroups = RuleAdapter.flatten(try decodeSentinelRuleTree(orWhenLeaves: testCase.leafJSON))
        #expect(
            typedGroups == jsonGroups,
            "\(testCase.description): typed-path and JSON-sentinel-path must produce identical RuleGroups"
        )
    }
}
