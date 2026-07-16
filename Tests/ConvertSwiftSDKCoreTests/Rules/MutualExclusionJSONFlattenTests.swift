// Tests/ConvertSwiftSDKCoreTests/Rules/MutualExclusionJSONFlattenTests.swift
//
// RED-phase suite for IOS-2 (M2 unit, iOS mutual-exclusion qs-03): `RuleAdapter` gains a path to
// flatten a rule tree FROM the sentinel `JSONValue` an audience degrades to when its rule tree embeds
// an unrecognised `rule_type` leaf (IOS-1's `ProjectConfig.degradedAudienceSentinels`, already
// committed — see `Sources/ConvertSwiftSDKCore/Data/ProjectConfig.swift`,
// `ProjectConfig+AudienceDecoding.swift`). Spec of record:
//   _bmad-output/implementation-artifacts/2026-06-09-convert-ios-sdk/qs-04-mutual-exclusion-rule.md
// Task/plan: work/2026-07-15-ios-sdk-mutual-exclusion/workflow-state.yaml (task IOS-2, "v18s").
// (Citation path corrected: ai-driven-product-dev#86 — qs-03 was renumbered/relocated to qs-04 under
// implementation-artifacts/ after this suite was authored. No behavioral change: this suite tests
// `RuleAdapter.flatten(_ sentinelRuleTree:)` detection output (a stateful leaf surviving alongside a
// generic sibling), which the qs-04 whole-audience-override rework — see the sibling
// `MutualExclusionRuleManagerTests.swift` header — does not touch; only the RESOLUTION of an already-
// detected stateful leaf moved out of `RuleManager`.)
//
// ── Why this must exist (consequence of IOS-1) ────────────────────────────────────────────────────
// A `bucketed_into_experience_key` leaf makes the WHOLE audience fail the generated typed decode
// (`unknownOneOfDiscriminator`), so IOS-1 sentinel-captures the ENTIRE degraded audience's raw JSON
// (id/key/name/rules — via `SentinelWrapped<Components.Schemas.ConfigAudience>`) into
// `ProjectConfig.degradedAudienceSentinels[id]`, rather than a typed `RuleObjectAudience`. The
// existing `RuleAdapter.flatten(_ audience: Components.Schemas.RuleObjectAudience)` overload can
// never see that audience's rule tree — it only ever runs against a TYPED graph, and a degraded
// audience's `rules` typed property is `nil` by construction (see
// `ProjectConfig+AudienceDecoding.swift`'s `reconstructAudience(fromSentinelPayload:)`). So the
// leaf's `rule_type`/`value`/`matching.negated` — and any generic sibling leaf in the SAME degraded
// tree — are only reachable by walking the CAPTURED `JSONValue` directly.
//
// None of the symbols this file exercises exist in Sources/ yet:
//   - `RuleAdapter.flatten(_ sentinelRuleTree: JSONValue) -> [RuleGroup]` (new overload)
//   - `RuleCondition.statefulTarget` / `StatefulRuleTarget` (see the sibling
//     `MutualExclusionRuleManagerTests.swift` header for the full assumed shape — not re-derived here)
// This file MUST fail to COMPILE ("type 'RuleAdapter' has no member 'flatten'" for a `JSONValue`
// argument / "cannot find 'StatefulRuleTarget' in scope") — the expected, correct RED state, and (as
// with the sibling suite) breaks `swift build`/`swift test` for the WHOLE `ConvertSwiftSDKCoreTests`
// target until GREEN lands — unavoidable in a single-SPM-module target, matching the accepted RED
// shape of IOS-1's own suites.
//
// ── ASSUMED SHAPE (spec-silent — IOS-2 implementation choice) ────────────────────────────────────
//   extension RuleAdapter {
//       static func flatten(_ sentinelRuleTree: JSONValue) -> [RuleGroup]
//   }
// Chosen as an OVERLOAD of the EXISTING `flatten(_:)` name (dispatched by parameter TYPE), symmetric
// with the two typed overloads already present (`flatten(_ audience: RuleObjectAudience)` /
// `flatten(_ location: RuleObject)` — `RuleAdapter.swift` lines 49/65). The parameter is the "rules"
// SUB-TREE node — i.e. the JSON shape `{"OR": [...]}` — NOT the whole audience object: this mirrors
// the typed overloads exactly, which likewise take `RuleObjectAudience`/`RuleObject` (themselves the
// `rules` sub-tree's typed shape, per `ConfigAudience.rulesPayload.value1: RuleObjectAudience`,
// `ConfigSchemas.swift:46-64`), not the enclosing `ConfigAudience`. A caller sitting on
// `ProjectConfig.degradedAudienceSentinels[id]` (the FULL audience payload) is expected to navigate
// to the `"rules"` member itself before calling `RuleAdapter.flatten(_:)` — that one-hop navigation
// is a future (IOS-3) consumer's job, not re-tested here; this suite feeds the rules sub-tree
// directly, exactly as `RuleAdapterTests`'s existing typed-path tests feed `RuleObjectAudience`
// directly rather than a whole `ConfigAudience`.
//
// Extraction contract this suite pins:
//   - A leaf whose `rule_type == "bucketed_into_experience_key"` maps to a `RuleCondition` whose
//     `statefulTarget` is non-nil: `ruleType` = the leaf's `rule_type` string, `targetExperienceKey`
//     = the leaf's `value` string, and `negation` = the leaf's `matching.negated` (defaulting to
//     `false` when absent, mirroring the typed-path default at `RuleAdapter.make(...)`).
//   - Every OTHER (generic) leaf in the SAME JSON tree maps to the SAME `RuleCondition` the TYPED
//     path already produces for that leaf shape (AC7 parity) — see the sibling
//     `MutualExclusionGenericRegressionTests.swift` for the dedicated bit-identical regression lock;
//     THIS file only proves generic leaves survive ALONGSIDE a stateful leaf in one mixed tree, not
//     the full typed/JSON equivalence (kept isolated per the IOS-2 dispatch, so the two concerns
//     don't get entangled in one suite).
//   - The OR -> AND -> OR_WHEN collapse is IDENTICAL to the typed path: one `RuleGroup` per AND-block,
//     that block's `OR_WHEN` leaves collected into `conditions` — reusing, not forking, the
//     collapsing semantics (AC7's "reuse, do not fork the OR/AND/OR_WHEN semantics").
//
// SonarQube `new_duplicated_lines_density` guard: ONE shared `makeSentinelRuleTree` envelope helper
// (mirroring `RuleAdapterTests.makeAudienceRules`, decoding to `JSONValue` instead of the typed
// `RuleObjectAudience`) — no test repeats the `OR -> AND -> OR_WHEN` envelope literal.

import Foundation
import Testing
@testable import ConvertSwiftSDKCore

@Suite("RuleAdapter JSON-sentinel flatten (bucketed_into_experience_key) — IOS-2 RED")
struct MutualExclusionJSONFlattenTests {

    // MARK: - Fixture factory (single decode site — SonarQube duplication guard)

    /// Wraps caller-supplied OR_WHEN leaf-array JSON in the fixed `OR -> AND -> OR_WHEN` envelope
    /// (verified against `Components.Schemas.RuleObjectAudience`, `ConfigSchemas.swift:3613-3667`,
    /// and reused verbatim from `RuleAdapterTests.makeAudienceRules`'s envelope literal) and decodes
    /// it as a raw `JSONValue` tree instead of the typed `RuleObjectAudience` — the shape a
    /// degraded audience's sentinel-captured `rules` sub-tree has.
    private func makeSentinelRuleTree(orWhenLeaves leavesJSON: String) throws -> JSONValue {
        let envelope = """
        { "OR": [ { "AND": [ { "OR_WHEN": [ \(leavesJSON) ] } ] } ] }
        """
        return try JSONDecoder().decode(JSONValue.self, from: Data(envelope.utf8))
    }

    // MARK: - Mixed stateful + generic leaf, one AND-block

    /// A `bucketed_into_experience_key` leaf and a generic `city` leaf sharing ONE OR_WHEN array
    /// flatten to exactly one `RuleGroup` carrying two conditions: one stateful, one plain — proving
    /// the new leaf family survives ALONGSIDE an existing family in the same degraded tree, and that
    /// the OR->AND->OR_WHEN collapse is untouched (still one group per AND-block).
    @Test("flatten(JSONValue): a stateful leaf + a generic leaf in one AND-block -> one group, two conditions")
    func flattenMixedStatefulAndGenericLeaf() throws {
        let ruleTree = try makeSentinelRuleTree(orWhenLeaves: """
        { "rule_type": "bucketed_into_experience_key", "value": "exp-a", \
        "matching": { "match_type": "equals", "negated": true } },
        { "rule_type": "city", "value": "NYC", "matching": { "match_type": "matches" } }
        """)

        let groups = RuleAdapter.flatten(ruleTree)
        #expect(groups.count == 1, "one AND-block must flatten to exactly one RuleGroup")
        let conditions = groups.first?.conditions ?? []
        #expect(conditions.count == 2, "both OR_WHEN leaves must survive as conditions")

        let stateful = try #require(
            conditions.first { $0.statefulTarget != nil },
            "the bucketed_into_experience_key leaf must produce a condition with a non-nil statefulTarget"
        )
        #expect(
            stateful.statefulTarget?.ruleType == "bucketed_into_experience_key",
            "statefulTarget.ruleType must carry the leaf's rule_type discriminator"
        )
        #expect(
            stateful.statefulTarget?.targetExperienceKey == "exp-a",
            "statefulTarget.targetExperienceKey must carry the leaf's value (the target experience key)"
        )
        #expect(stateful.negation == true, "matching.negated (true) must map onto RuleCondition.negation")

        let generic = try #require(
            conditions.first { $0.statefulTarget == nil },
            "the city leaf must still produce a plain (non-stateful) condition"
        )
        #expect(generic.key == "city")
        #expect(generic.value == "NYC")
        #expect(generic.matchType == "matches")
        #expect(generic.negation == false, "the city leaf omits matching.negated, defaulting to false")
    }

    // MARK: - Lone stateful leaf

    /// A lone `bucketed_into_experience_key` leaf (no sibling) still flattens to one group / one
    /// condition, with `matching.negated == false` correctly reflected (not defaulted true by
    /// accident) and no attribute-lookup fields populated.
    @Test("flatten(JSONValue): a lone stateful leaf survives with negation == false intact")
    func flattenLoneStatefulLeafNonNegated() throws {
        let ruleTree = try makeSentinelRuleTree(orWhenLeaves: """
        { "rule_type": "bucketed_into_experience_key", "value": "exp-b", \
        "matching": { "match_type": "equals", "negated": false } }
        """)

        let groups = RuleAdapter.flatten(ruleTree)
        #expect(groups.count == 1)
        let condition = try #require(groups.first?.conditions.first)
        #expect(condition.statefulTarget?.ruleType == "bucketed_into_experience_key")
        #expect(condition.statefulTarget?.targetExperienceKey == "exp-b")
        #expect(condition.negation == false)
    }

    // MARK: - Two AND-blocks (OR of stateful-only vs generic-only), collapse fidelity

    /// Two SEPARATE AND-blocks — one holding only the stateful leaf, one holding only a generic
    /// leaf — flatten to TWO `RuleGroup`s (the outer-OR), each with exactly one condition. Pins that
    /// the JSON-path collapse does not merge sibling AND-blocks the way it must not merge sibling
    /// OR_WHEN leaves into extra groups either.
    @Test("flatten(JSONValue): two AND-blocks (stateful-only, generic-only) -> two groups")
    func flattenTwoSeparateAndBlocks() throws {
        let envelope = """
        { "OR": [
            { "AND": [ { "OR_WHEN": [
                { "rule_type": "bucketed_into_experience_key", "value": "exp-a", \
        "matching": { "match_type": "equals", "negated": false } }
            ] } ] },
            { "AND": [ { "OR_WHEN": [
                { "rule_type": "country", "value": "US", "matching": { "match_type": "equals" } }
            ] } ] }
        ] }
        """
        let ruleTree = try JSONDecoder().decode(JSONValue.self, from: Data(envelope.utf8))

        let groups = RuleAdapter.flatten(ruleTree)
        #expect(groups.count == 2, "two AND-blocks under the outer OR must flatten to two RuleGroups")
        let statefulGroups = groups.filter { $0.conditions.contains { $0.statefulTarget != nil } }
        let genericGroups = groups.filter { $0.conditions.contains { $0.statefulTarget == nil } }
        #expect(statefulGroups.count == 1, "exactly one group must hold the stateful-only leaf")
        #expect(genericGroups.count == 1, "exactly one group must hold the generic-only leaf")
    }
}
