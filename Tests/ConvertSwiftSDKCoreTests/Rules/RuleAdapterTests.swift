// Tests/ConvertSwiftSDKCoreTests/Rules/RuleAdapterTests.swift
// Adapter suite for `RuleAdapter.flatten(_:)` (Epic 3 / Story 4 — RA-1): flatten the generated
// 3-level `RuleObjectAudience` graph (OR → AND → OR_WHEN → RuleElementAudience leaf) into the
// flat `[RuleGroup]` model that `RuleManager.evaluate(rules:against:)` (Story 3.3) consumes.
//
// RED phase (TDD): `RuleAdapter` does NOT exist yet (Sources/ConvertSwiftSDKCore/Rules/RuleAdapter.swift
// is unwritten). This file MUST fail to compile with "cannot find 'RuleAdapter' in scope" — that is
// the expected, correct RED state. The expectations below define the contract the to-be-built
// adapter has to satisfy. The fixtures decode REAL wire JSON through the generated
// `Components.Schemas.RuleObjectAudience` decoder, so they also pin the on-the-wire shape.
//
// MAPPING CONTRACT (Story 3.3 hand-off + verified generated field paths):
//   - `RuleObjectAudience.OR` (outer)            → the `[RuleGroup]` outer-OR.
//   - each `ORPayloadPayload.AND` + its leaf list → flattened into `RuleGroup.conditions`.
//   - per leaf `RuleElementAudience`:
//       * `RuleCondition.key`       = the discriminator / rule_type case name ("city", "country").
//       * `RuleCondition.matchType` = the `match_type` rawValue String ("matches", "equals", ...).
//       * `RuleCondition.value`     = the rule's string value (BaseRuleWith*Value.value2.value).
//       * `RuleCondition.negation`  = BaseMatch.negated (defaulting to false when absent).
//   - an unmappable leaf (no `matching` block → nil match_type) degrades to a matchType that is
//     NOT in `Comparisons.comparators`, so `Comparisons` fails closed (returns false) — never crashes.
//
// VERIFIED LEAF WIRE SHAPE (read from ConfigSchemas.swift): `RuleElementAudience` decodes via the
// top-level `rule_type` discriminator; the chosen leaf type then decodes `value1`/`value2` from the
// SAME flat object (generated allOf flattening — `value1 = try .init(from: decoder)` etc.). So one
// `city` leaf is a flat object:
//     { "rule_type": "city", "value": "NYC", "matching": { "negated": false, "match_type": "matches" } }
//   - `rule_type`           → discriminator + BaseRule.rule_type (value1.value1) + value2.rule_type.
//   - `value`               → BaseRuleWithStringValue.value2.value (value1.value2.value).
//   - `matching.negated`    → BaseMatch.negated (value2.matching.value1.negated).
//   - `matching.match_type` → TextMatchingOptions (value2.matching.value2.match_type); the `matching`
//                             object is itself flattened, so `negated` + `match_type` are siblings.
// `country` is structurally parallel (CountryMatchRule); its value lives in
// BaseRuleWithCountryCodeValue.value2.value, and its match_type enum (ChoiceMatchingOptions) only
// admits "equals" — which is a live key in `Comparisons.comparators`, so it evaluates end-to-end.

import Foundation
import Testing
@testable import ConvertSwiftSDKCore

@Suite("RuleAdapter")
struct RuleAdapterTests {

    // MARK: - Fixture factory (single decode site — SonarQube duplication guard)

    /// Sole decode site. Wraps a caller-supplied OR_WHEN leaf-array JSON in the fixed
    /// `OR → [ AND → [ OR_WHEN → [ … ] ] ]` envelope and decodes it into the real generated
    /// `RuleObjectAudience`. Every test routes its leaf JSON through here so the envelope literal
    /// and the `JSONDecoder` call are each written exactly once (keeps `new_duplicated_lines_density`
    /// ≤ 3% and proves each leaf decodes through the actual wire-shape decoder).
    ///
    /// - Parameter leavesJSON: the JSON for the `OR_WHEN` array's elements, e.g.
    ///   `{"rule_type":"city","value":"NYC","matching":{"negated":false,"match_type":"matches"}}`.
    ///   Pass multiple comma-separated leaf objects to populate one AND block with several leaves.
    private func makeAudienceRules(orWhenLeaves leavesJSON: String) throws
        -> Components.Schemas.RuleObjectAudience {
        let envelope = """
        { "OR": [ { "AND": [ { "OR_WHEN": [ \(leavesJSON) ] } ] } ] }
        """
        return try JSONDecoder().decode(
            Components.Schemas.RuleObjectAudience.self,
            from: Data(envelope.utf8)
        )
    }

    // MARK: - Leaf-mapping contract

    /// A single `city` text leaf (match_type "matches", value "NYC", `negated` absent) flattens to
    /// exactly one RuleGroup with one RuleCondition: key "city", matchType "matches", value "NYC",
    /// negation false (the default when `negated` is omitted from the `matching` block).
    @Test("flatten: single text equals leaf → one group, one condition")
    func flattenSingleTextEqualsLeaf() throws {
        let audience = try makeAudienceRules(
            orWhenLeaves: #"{ "rule_type": "city", "value": "NYC", "matching": { "match_type": "matches" } }"#
        )
        let groups = RuleAdapter.flatten(audience)
        #expect(groups.count == 1)
        #expect(groups.first?.conditions == [
            RuleCondition(key: "city", matchType: "matches", value: "NYC", negation: false)
        ])
    }

    /// The same `city` leaf but with `matching.negated == true` → the produced RuleCondition carries
    /// `negation == true` (BaseMatch.negated maps straight onto RuleCondition.negation).
    @Test("flatten: negated leaf → condition.negation == true")
    func flattenNegatedLeaf() throws {
        let audience = try makeAudienceRules(
            orWhenLeaves: #"{ "rule_type": "city", "value": "NYC", "#
                + #""matching": { "negated": true, "match_type": "matches" } }"#
        )
        let condition = RuleAdapter.flatten(audience).first?.conditions.first
        #expect(condition?.negation == true)
        #expect(condition?.key == "city")
        #expect(condition?.value == "NYC")
    }

    /// One AND block containing two OR_WHEN leaves (`city` + `country`) flattens so that BOTH leaves
    /// appear as conditions in the reconciled output. Asserts the count and the set of keys without
    /// over-specifying the internal OR/AND/OR_WHEN collapse onto the flat 2-level model.
    @Test("flatten: multiple OR_WHEN leaves → multiple conditions")
    func flattenMultipleORWHENBecomeMultipleConditionsInGroup() throws {
        let audience = try makeAudienceRules(orWhenLeaves: """
        { "rule_type": "city", "value": "NYC", "matching": { "match_type": "matches" } },
        { "rule_type": "country", "value": "US", "matching": { "match_type": "equals" } }
        """)
        let groups: [RuleGroup] = RuleAdapter.flatten(audience)
        let conditions: [RuleCondition] = groups.flatMap { $0.conditions }
        let keys: Set<String> = Set(conditions.map { $0.key })
        #expect(conditions.count == 2)
        #expect(keys == ["city", "country"])
    }

    // MARK: - End-to-end consumability through RuleManager + Comparisons

    /// END-TO-END: a `country == "US"` audience, once flattened, is consumed correctly by the REAL
    /// `RuleManager` + `Comparisons` — true against `["country": "US"]`, false against
    /// `["country": "UK"]`. Proves the adapter output is both consumable and semantically correct.
    @Test("flatten: result evaluates correctly through RuleManager")
    func flattenedRulesEvaluateThroughRuleManager() throws {
        let audience = try makeAudienceRules(
            orWhenLeaves: #"{ "rule_type": "country", "value": "US", "matching": { "match_type": "equals" } }"#
        )
        let manager = RuleManager(logger: MockLogger())
        let flattened = RuleAdapter.flatten(audience)
        #expect(manager.evaluate(rules: flattened, against: ["country": "US"]) == true)
        #expect(manager.evaluate(rules: flattened, against: ["country": "UK"]) == false)
    }

    /// The produced matchType string is a value `Comparisons` accepts (a `TextMatchingOptions`
    /// rawValue passes through verbatim): a `city contains "NY"` leaf matches `["city": "NYC"]`.
    /// Conversely, a leaf with NO `matching` block (nil match_type → unmappable operator) degrades
    /// so `Comparisons` fails closed — evaluate returns false even when the attribute is present.
    @Test("flatten: matchType passes through to comparators; unmappable fails closed")
    func matchTypeRawValuePassesThroughToComparators() throws {
        let manager = RuleManager(logger: MockLogger())

        let passThrough = try makeAudienceRules(
            orWhenLeaves: #"{ "rule_type": "city", "value": "NY", "matching": { "match_type": "contains" } }"#
        )
        #expect(manager.evaluate(rules: RuleAdapter.flatten(passThrough), against: ["city": "NYC"]) == true)

        let unmappable = try makeAudienceRules(
            orWhenLeaves: #"{ "rule_type": "city", "value": "NYC" }"#
        )
        #expect(manager.evaluate(rules: RuleAdapter.flatten(unmappable), against: ["city": "NYC"]) == false)
    }

    // MARK: - Newly-covered attribute-lookup families (iOS rule-family parity with Android/JS)

    /// The attribute-lookup families that previously degraded fail-closed now flatten to REAL
    /// conditions. Named families (`visits_count`, `is_desktop`, `cookie`, `language`) key off
    /// `rule_type`; the key-value families key off their EXPLICIT `key` (mirroring JS `rule['key']` /
    /// Android `lookupAttribute`). Each `match_type` is a valid rawValue for that family's matching
    /// enum (cookie uses `CookieMatchingOptions`, which has `matches` not `equals`) so the leaf decodes.
    @Test("flatten: numeric / bool / cookie / language + key-value families are no longer degraded")
    func flattenNewlyCoveredFamilies() throws {
        let audience = try makeAudienceRules(orWhenLeaves: """
        { "rule_type": "visits_count", "value": 5, "matching": { "match_type": "less" } },
        { "rule_type": "is_desktop", "value": true, "matching": { "match_type": "equals" } },
        { "rule_type": "cookie", "value": "abc", "matching": { "match_type": "matches" } },
        { "rule_type": "language", "value": "en", "matching": { "match_type": "equals" } },
        { "rule_type": "generic_numeric_key_value", "key": "age", "value": 30,
          "matching": { "match_type": "lessEqual" } },
        { "rule_type": "generic_bool_key_value", "key": "vip", "value": true,
          "matching": { "match_type": "equals" } }
        """)
        let byKey = Dictionary(
            RuleAdapter.flatten(audience).flatMap(\.conditions).map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Named families: keyed off rule_type, operator preserved (a degrade would be an empty matchType).
        for key in ["visits_count", "is_desktop", "cookie", "language"] {
            let condition = try #require(byKey[key], "\(key) must flatten to a real condition, not degrade")
            #expect(!condition.matchType.isEmpty, "\(key) keeps its match operator")
            #expect(condition.value != nil, "\(key) keeps its value")
        }
        // Key-value families resolve their EXPLICIT `key` (not the rule_type).
        #expect(byKey["age"]?.matchType == "lessEqual", "generic_numeric_key_value keys off 'age'")
        #expect(byKey["vip"]?.value == "true", "generic_bool_key_value keys off 'vip', bool stringified")
    }

    /// END-TO-END: a newly-covered family is consumable through the REAL `RuleManager` — an
    /// `is_desktop equals "true"` leaf matches `["is_desktop": "true"]` and not `["is_desktop": "false"]`.
    @Test("flatten: a newly-covered (bool) family evaluates through RuleManager")
    func newlyCoveredFamilyEvaluatesThroughRuleManager() throws {
        let audience = try makeAudienceRules(
            orWhenLeaves: #"{ "rule_type": "is_desktop", "value": true, "matching": { "match_type": "equals" } }"#
        )
        let manager = RuleManager(logger: MockLogger())
        let flattened = RuleAdapter.flatten(audience)
        #expect(manager.evaluate(rules: flattened, against: ["is_desktop": "true"]) == true)
        #expect(manager.evaluate(rules: flattened, against: ["is_desktop": "false"]) == false)
    }
}
