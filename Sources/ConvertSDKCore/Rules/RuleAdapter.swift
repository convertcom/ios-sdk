// RuleAdapter.swift
// Flattens the generated 3-level audience / location rule graphs into the flat [RuleGroup] model
// (Epic 3 / Story 4 — RA-1; per the Story 3.3 hand-off contract).
//
// SHAPE — the generated `RuleObjectAudience` (audiences) and `RuleObject` (locations / site_area)
// are structurally identical: `OR → AND → OR_WHEN → <leaf>` (ConfigSchemas.swift 3552 / 3613). The
// outer `OR` is a list of AND-blocks; each AND-block's `OR_WHEN` is a list of leaf conditions. They
// differ ONLY in the leaf enum: `RuleObjectAudience` leaves are `RuleElementAudience`, `RuleObject`
// leaves are `RuleElement`. The flat target model is `[RuleGroup]` (outer OR) of
// `RuleGroup { conditions }` (inner AND), consumed by `RuleManager.evaluate(rules:against:)`.
//
// COLLAPSE — one `RuleGroup` is emitted per AND-block; that block's `OR_WHEN` leaves are collected
// into the group's `conditions`. This is the observable contract the RA-1 tests pin: a single
// AND-block with one leaf → one group / one condition; a single AND-block with two leaves → both
// leaves appear as conditions (RuleAdapterTests `flattenMultiple…`).
//
// COVERAGE (bd-d4p) — per-leaf extraction handles the two families the tests exercise and that share
// an identical field layout: the `GenericTextMatchRule`-backed text family (city, campaign, keyword,
// medium, region, url, page_tag_*, …) and `CountryMatchRule` (country). Both expose the same paths
// (verified against ConfigSchemas.swift) and — crucially — the SAME concrete leaf struct types are
// reused across BOTH leaf enums, so a single pair of struct-keyed extractors (`condition(fromText:)`
// / `condition(fromCountry:)`) serves the audience AND location switches:
//     key        = value1.value1.rule_type                       (BaseRule.rule_type — the wire
//                                                                  discriminator, NOT hardcoded)
//     value      = value1.value2.value                           (BaseRuleWith*Value.value2.value)
//     negation   = value2.matching?.value1.negated   ?? false    (BaseMatch.negated)
//     matchType  = value2.matching?.value2.match_type?.rawValue ?? ""
// Every OTHER leaf family (numeric / bool / cookie / segment / js_condition / …) degrades to a
// fail-closed condition: `matchType = ""`, which is absent from `Comparisons.comparators`, so
// `Comparisons.evaluate` returns false without ever matching wrong-positive. Full coverage is
// deferred (bd-d4p). The empty-string `matchType` ALSO covers a handled-family leaf with no
// `matching` block (nil match_type) — it degrades the same fail-closed way.
//
// Foundation-only — pure mapping over decoded value types; no platform framework, no state.

import Foundation

/// Flattens the generated 3-level audience / location rule graphs into the flat `[RuleGroup]`
/// model `RuleManager` consumes (Story 3.4 adapter; per the Story 3.3 hand-off).
internal enum RuleAdapter {

    /// Flattens an audience rule object (`OR → AND → OR_WHEN → RuleElementAudience`) into the flat
    /// `[RuleGroup]` outer-OR: one `RuleGroup` per AND-block, whose `conditions` are that block's
    /// `OR_WHEN` leaves mapped to ``RuleCondition``s.
    ///
    /// - Parameter audience: The decoded generated audience rule graph.
    /// - Returns: The flat outer-OR of AND-groups. An absent `OR` yields an empty array (which
    ///   `RuleManager` treats as fail-closed).
    static func flatten(_ audience: Components.Schemas.RuleObjectAudience) -> [RuleGroup] {
        (audience.OR ?? []).map { andBlock in
            let leaves = (andBlock.AND ?? []).flatMap { $0.OR_WHEN ?? [] }
            return RuleGroup(conditions: leaves.map(condition(fromAudienceLeaf:)))
        }
    }

    /// Flattens a location / site_area rule object (`OR → AND → OR_WHEN → RuleElement`) into the
    /// flat `[RuleGroup]` outer-OR — structurally identical to ``flatten(_:)`` over an audience, but
    /// over the `RuleElement` leaf enum. One `RuleGroup` per AND-block, whose `conditions` are that
    /// block's `OR_WHEN` leaves mapped to ``RuleCondition``s.
    ///
    /// - Parameter location: The decoded generated location rule graph (`ConfigLocation.rules`'s
    ///   inner `value1`, or an experience's `site_area` value1).
    /// - Returns: The flat outer-OR of AND-groups. An absent `OR` yields an empty array (which
    ///   `RuleManager` treats as fail-closed).
    static func flatten(_ location: Components.Schemas.RuleObject) -> [RuleGroup] {
        (location.OR ?? []).map { andBlock in
            let leaves = (andBlock.AND ?? []).flatMap { $0.OR_WHEN ?? [] }
            return RuleGroup(conditions: leaves.map(condition(fromLocationLeaf:)))
        }
    }

    /// Maps one generated AUDIENCE leaf to a flat ``RuleCondition`` by routing the text and country
    /// families to the shared struct-keyed extractors; every other family degrades fail-closed.
    private static func condition(
        fromAudienceLeaf leaf: Components.Schemas.RuleElementAudience
    ) -> RuleCondition {
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
            return condition(fromText: rule)
        case let .country(rule):
            return condition(fromCountry: rule)
        default:
            // INTENTIONAL fail-closed degrade (bd-d4p deferred-coverage boundary): every leaf family
            // NOT enumerated above (numeric / bool / cookie / segment / js_condition / weather / os /
            // language / time-of-day / …) maps to an empty-`matchType` ``RuleCondition`` that
            // ``Comparisons`` never matches — so an unmapped operator can only fail closed, never
            // wrong-positive. No runtime log is emitted at THIS site by design: the unhandled cases are
            // heterogeneous (each carries a DIFFERENT concrete rule struct — `GenericNumericMatchRule`,
            // `GenericBoolMatchRule`, `CookieMatchRule`, … — that share NO protocol exposing
            // `rule_type`), so recovering the discriminator string for a diagnostic would force binding
            // all ~30 cases individually here, which is the ripple the degrade is meant to avoid. When
            // bd-d4p lands a family, ADD its `case let .x(rule):` to the list above — do not log here.
            return degraded()
        }
    }

    /// Maps one generated LOCATION leaf to a flat ``RuleCondition`` — the `RuleElement` parallel of
    /// ``condition(fromAudienceLeaf:)``, routing the same families to the same shared extractors.
    /// (`RuleElement` lacks `visitor_id` and adds `weather_condition`; the case list reflects that,
    /// while every unhandled family — `weather_condition` included — degrades fail-closed.)
    private static func condition(
        fromLocationLeaf leaf: Components.Schemas.RuleElement
    ) -> RuleCondition {
        switch leaf {
        case let .browser_version(rule), let .campaign(rule), let .city(rule),
             let .keyword(rule), let .medium(rule), let .page_tag_category_id(rule),
             let .page_tag_category_name(rule), let .page_tag_custom_1(rule),
             let .page_tag_custom_2(rule), let .page_tag_custom_3(rule),
             let .page_tag_custom_4(rule), let .page_tag_customer_id(rule),
             let .page_tag_page_type(rule), let .page_tag_product_name(rule),
             let .page_tag_product_sku(rule), let .query_string(rule), let .region(rule),
             let .source_name(rule), let .url(rule), let .url_with_query(rule),
             let .user_agent(rule):
            return condition(fromText: rule)
        case let .country(rule):
            return condition(fromCountry: rule)
        default:
            // INTENTIONAL fail-closed degrade (bd-d4p) — the `RuleElement` parallel of the audience
            // `default:` above (`weather_condition` is one such unhandled family here). Same contract:
            // an unmapped leaf gets an empty-`matchType` ``RuleCondition`` ``Comparisons`` never
            // matches (fail-closed, never wrong-positive), and no runtime log is emitted at this site —
            // see the audience switch's `default:` for why the heterogeneous leaf structs make
            // discriminator recovery here not worth the ~30-case binding ripple.
            return degraded()
        }
    }

    /// Extracts a ``RuleCondition`` from a text-family leaf (`GenericTextMatchRule`), shared by the
    /// audience and location switches (the same concrete struct backs both leaf enums).
    private static func condition(
        fromText rule: Components.Schemas.GenericTextMatchRule
    ) -> RuleCondition {
        make(
            key: rule.value1.value1.rule_type,
            value: rule.value1.value2.value,
            negated: rule.value2.matching?.value1.negated,
            matchType: rule.value2.matching?.value2.match_type?.rawValue
        )
    }

    /// Extracts a ``RuleCondition`` from the country leaf (`CountryMatchRule`), shared by the
    /// audience and location switches (the same concrete struct backs both leaf enums).
    private static func condition(
        fromCountry rule: Components.Schemas.CountryMatchRule
    ) -> RuleCondition {
        make(
            key: rule.value1.value1.rule_type,
            value: rule.value1.value2.value,
            negated: rule.value2.matching?.value1.negated,
            matchType: rule.value2.matching?.value2.match_type?.rawValue
        )
    }

    /// Builds a ``RuleCondition`` from the four extracted fields, applying the documented defaults:
    /// an absent `match_type` becomes `""` (fail-closed in ``Comparisons``); an absent `negated`
    /// becomes `false`.
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

    /// A fail-closed condition for a leaf family not yet handled — the INTENTIONAL degrade at the
    /// bd-d4p deferred-coverage boundary, emitted from both switches' `default:` arms. The empty
    /// `matchType` is absent from ``Comparisons/comparators``, so the condition evaluates to false —
    /// never a wrong-positive. `key` is left empty because no attribute lookup can succeed once the
    /// operator is unmapped. Extending coverage means adding the leaf's `case` to the switches above,
    /// NOT changing this fail-closed default.
    private static func degraded() -> RuleCondition {
        RuleCondition(key: "", matchType: "", value: nil, negation: false)
    }
}
