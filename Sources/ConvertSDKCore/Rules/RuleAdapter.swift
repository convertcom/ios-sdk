// RuleAdapter.swift
// Flattens the generated 3-level audience rule graph into the flat [RuleGroup] model
// (Epic 3 / Story 4 — RA-1; per the Story 3.3 hand-off contract).
//
// SHAPE — the generated `RuleObjectAudience` is `OR → AND → OR_WHEN → RuleElementAudience`
// (ConfigSchemas.swift 3544-3548): the outer `OR` is a list of AND-blocks; each AND-block's
// `OR_WHEN` is a list of leaf conditions. The flat target model is `[RuleGroup]` (outer OR)
// of `RuleGroup { conditions }` (inner AND), consumed by `RuleManager.evaluate(rules:against:)`.
//
// COLLAPSE — one `RuleGroup` is emitted per AND-block; that block's `OR_WHEN` leaves are
// collected into the group's `conditions`. This is the observable contract the RA-1 tests
// pin: a single AND-block with one leaf → one group / one condition; a single AND-block with
// two leaves → both leaves appear as conditions (RuleAdapterTests `flattenMultiple…`).
//
// COVERAGE (bd-d4p) — per-leaf extraction handles the two families the audience tests exercise
// and that share an identical field layout: the `GenericTextMatchRule`-backed text family
// (city, campaign, keyword, medium, region, url, page_tag_*, …) and `CountryMatchRule`
// (country). Both expose the same paths (verified against ConfigSchemas.swift):
//     key        = value1.value1.rule_type                       (BaseRule.rule_type, the wire
//                                                                  discriminator — NOT hardcoded)
//     value      = value1.value2.value                           (BaseRuleWith*Value.value2.value)
//     negation   = value2.matching?.value1.negated   ?? false    (BaseMatch.negated)
//     matchType  = value2.matching?.value2.match_type?.rawValue ?? ""
// Every OTHER leaf family (numeric / bool / cookie / segment / js_condition / …) degrades to a
// fail-closed condition: `matchType = ""`, which is absent from `Comparisons.comparators`, so
// `Comparisons.evaluate` returns false without ever matching wrong-positive. Full 57-case
// coverage is deferred (bd-d4p). The empty-string `matchType` ALSO covers a handled-family leaf
// with no `matching` block (nil match_type) — it degrades the same fail-closed way.
//
// Foundation-only — pure mapping over decoded value types; no platform framework, no state.

import Foundation

/// Flattens the generated 3-level audience/location rule graph into the flat `[RuleGroup]`
/// model `RuleManager` consumes (Story 3.4 adapter; per the Story 3.3 hand-off).
internal enum RuleAdapter {

    /// Flattens an audience rule object (`OR → AND → OR_WHEN → RuleElementAudience`) into the
    /// flat `[RuleGroup]` outer-OR: one `RuleGroup` per AND-block, whose `conditions` are that
    /// block's `OR_WHEN` leaves mapped to ``RuleCondition``s.
    ///
    /// - Parameter audience: The decoded generated audience rule graph.
    /// - Returns: The flat outer-OR of AND-groups. An absent `OR` yields an empty array (which
    ///   `RuleManager` treats as fail-closed).
    static func flatten(_ audience: Components.Schemas.RuleObjectAudience) -> [RuleGroup] {
        (audience.OR ?? []).map { andBlock in
            let leaves = (andBlock.AND ?? []).flatMap { $0.OR_WHEN ?? [] }
            return RuleGroup(conditions: leaves.map(condition(from:)))
        }
    }

    /// Maps one generated audience leaf to a flat ``RuleCondition``.
    ///
    /// The text and country families (identical field layout) extract their wire `rule_type`,
    /// value, `negated`, and `match_type`; every other family degrades to a fail-closed
    /// condition (empty `matchType`, absent from ``Comparisons``).
    private static func condition(from leaf: Components.Schemas.RuleElementAudience) -> RuleCondition {
        switch leaf {
        case let .browser_version(rule), let .campaign(rule), let .city(rule),
             let .keyword(rule), let .medium(rule), let .page_tag_category_id(rule),
             let .page_tag_category_name(rule), let .page_tag_custom_1(rule),
             let .page_tag_custom_2(rule), let .page_tag_custom_3(rule),
             let .page_tag_custom_4(rule), let .page_tag_customer_id(rule),
             let .page_tag_page_type(rule), let .page_tag_product_name(rule),
             let .page_tag_product_sku(rule), let .query_string(rule), let .region(rule),
             let .source_name(rule), let .url(rule), let .url_with_query(rule),
             let .user_agent(rule), let .visitor_id(rule):
            return make(
                key: rule.value1.value1.rule_type,
                value: rule.value1.value2.value,
                negated: rule.value2.matching?.value1.negated,
                matchType: rule.value2.matching?.value2.match_type?.rawValue
            )
        case let .country(rule):
            return make(
                key: rule.value1.value1.rule_type,
                value: rule.value1.value2.value,
                negated: rule.value2.matching?.value1.negated,
                matchType: rule.value2.matching?.value2.match_type?.rawValue
            )
        default:
            return degraded(leaf)
        }
    }

    /// Builds a ``RuleCondition`` from the four extracted fields, applying the documented
    /// defaults: an absent `match_type` becomes `""` (fail-closed in ``Comparisons``); an
    /// absent `negated` becomes `false`.
    private static func make(
        key: String,
        value: String?,
        negated: Bool?,
        matchType: String?
    ) -> RuleCondition {
        RuleCondition(
            key: key,
            matchType: matchType ?? "",
            value: value,
            negation: negated ?? false
        )
    }

    /// A fail-closed condition for a leaf family not yet handled (bd-d4p deferred). The empty
    /// `matchType` is absent from ``Comparisons/comparators``, so the condition evaluates to
    /// false — never a wrong-positive. `key` is left empty because no attribute lookup can
    /// succeed once the operator is unmapped.
    private static func degraded(_ leaf: Components.Schemas.RuleElementAudience) -> RuleCondition {
        RuleCondition(key: "", matchType: "", value: nil, negation: false)
    }
}
