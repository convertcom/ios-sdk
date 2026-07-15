// RuleAdapter+JSONSentinelFlatten.swift
// The JSON-sentinel flatten path (IOS-2, qs-03 mobile mutual-exclusion). Split into its OWN
// file purely to keep `RuleAdapter.swift` under SwiftLint's `file_length` / `type_body_length`
// gates — mirrors the `ProjectConfig+AudienceDecoding.swift` precedent (IOS-1), which split for
// the same reason rather than being an independent feature.
//
// A `bucketed_into_experience_key` leaf is an UNKNOWN `rule_type` discriminator to the generated
// schema, so it fails `Components.Schemas.RuleObjectAudience`'s typed decode
// (`unknownOneOfDiscriminator`) and the WHOLE audience degrades to a `JSONValue` sentinel
// (IOS-1 — `ProjectConfig.degradedAudienceSentinels`). `RuleAdapter.flatten(_ sentinelRuleTree:)`
// walks that raw JSON rule tree directly so a degraded audience's leaves — the stateful one AND
// any generic sibling in the SAME tree — still resolve, reusing (not forking) the OR/AND/OR_WHEN
// collapse and the shared `RuleAdapter.make(key:value:negated:matchType:)` / `degraded()` leaf
// builders (`RuleAdapter.swift`).
//
// Foundation-only — pure mapping over a decoded `JSONValue`; no platform framework, no state.

import Foundation

extension RuleAdapter {

    /// Rule-type discriminators whose match KEY is an explicit `key` member (`GenericKey`) rather
    /// than `rule_type` itself — the JSON-walk parallel of the typed switch's
    /// `condition(fromTextKeyValue:)` / `condition(fromNumericKeyValue:)` /
    /// `condition(fromBoolKeyValue:)` routing (`RuleAdapter.swift`).
    private static let keyValueRuleTypes: Set<String> = [
        "generic_text_key_value", "generic_numeric_key_value", "generic_bool_key_value"
    ]

    /// Named (non-key-value) `rule_type` discriminators the typed switch
    /// `RuleAdapter.condition(fromAudienceLeaf:)` (`RuleAdapter.swift`) routes to a LIVE extractor.
    /// This is the JSON-walk's coverage boundary and MUST match that switch's covered cases
    /// exactly, so a `rule_type` the typed switch does NOT enumerate (e.g. the stateful
    /// `bucketed_into_experience`, or any bd-d4p-deferred family) fails closed identically on both
    /// paths, never a wrong-positive. `condition(fromAudienceLeaf:)` is the source of truth — keep
    /// this set in sync with it by hand; it is not shared code because the typed switch's routing
    /// itself is out of scope for this JSON-walk feature.
    private static let namedFamilyRuleTypes: Set<String> = [
        // text family — condition(fromText:)
        "browser_version", "campaign", "city", "keyword", "medium",
        "page_tag_category_id", "page_tag_category_name", "page_tag_custom_1",
        "page_tag_custom_2", "page_tag_custom_3", "page_tag_custom_4",
        "page_tag_customer_id", "page_tag_page_type", "page_tag_product_name",
        "page_tag_product_sku", "query_string", "region", "source_name", "url",
        "url_with_query", "user_agent", "visitor_id",
        // country — condition(fromCountry:)
        "country",
        // numeric family — condition(fromNumeric:)
        "avg_time_page", "days_since_last_visit", "page_tag_product_price",
        "pages_visited_count", "visit_duration", "visits_count",
        // bool family — condition(fromBool:); NOTE `bucketed_into_experience` is ALSO
        // `GenericBoolMatchRule` but is deliberately NOT in this set, mirroring the typed switch's
        // `fromBool` doc comment that it stays unrouted (falls through to `default: degraded()`).
        "is_desktop", "is_mobile", "is_tablet",
        // singleton families
        "cookie", "language", "browser_name", "os"
    ]

    /// Flattens a `rules` sub-tree captured as a raw `JSONValue` sentinel (the shape a degraded
    /// audience's `rules` member has — see `ProjectConfig+AudienceDecoding.swift`) into the same
    /// flat `[RuleGroup]` model the typed overloads in `RuleAdapter.swift` produce: one
    /// `RuleGroup` per AND-block, whose `conditions` are that block's `OR_WHEN` leaves.
    ///
    /// - Parameter sentinelRuleTree: The `{"OR": [...]}` rules sub-tree, decoded as `JSONValue`.
    /// - Returns: The flat outer-OR of AND-groups. A non-object root, or an absent/non-array
    ///   `OR` member, yields an empty array (fail-closed, same as the typed overloads).
    static func flatten(_ sentinelRuleTree: JSONValue) -> [RuleGroup] {
        guard
            case let .object(rootPairs) = sentinelRuleTree,
            let orBlocks = arrayValue(of: "OR", in: rootPairs)
        else {
            return []
        }
        return orBlocks.map { andBlockValue in
            let leaves = andBlockLeaves(andBlockValue)
            return RuleGroup(conditions: leaves.map(condition(fromSentinelLeaf:)))
        }
    }

    /// Collects one AND-block's `OR_WHEN` leaves (flattening across every `AND` entry, mirroring
    /// the typed overloads' `(andBlock.AND ?? []).flatMap { $0.OR_WHEN ?? [] }`).
    private static func andBlockLeaves(_ andBlockValue: JSONValue) -> [JSONValue] {
        guard
            case let .object(andBlockPairs) = andBlockValue,
            let andEntries = arrayValue(of: "AND", in: andBlockPairs)
        else {
            return []
        }
        return andEntries.flatMap { andEntryValue -> [JSONValue] in
            guard
                case let .object(andEntryPairs) = andEntryValue,
                let orWhenLeaves = arrayValue(of: "OR_WHEN", in: andEntryPairs)
            else {
                return []
            }
            return orWhenLeaves
        }
    }

    /// Maps one raw JSON leaf to a flat ``RuleCondition``. A `bucketed_into_experience_key`
    /// `rule_type` produces a condition carrying a non-nil ``StatefulRuleTarget`` (`value` ->
    /// `targetExperienceKey`, `matching.negated` -> `negation`); every other `rule_type` reuses
    /// the SAME `RuleAdapter.make(...)` builder the typed path's per-family extractors call,
    /// keyed off either the explicit `key` member (the three key-value families) or `rule_type`
    /// itself (every named family) — the JSON-walk parallel of the typed switches' routing.
    private static func condition(fromSentinelLeaf leaf: JSONValue) -> RuleCondition {
        guard case let .object(pairs) = leaf else { return degraded() }
        let ruleType = stringValue(of: "rule_type", in: pairs) ?? ""
        let matchingPairs = objectPairs(of: "matching", in: pairs)
        let negated = matchingPairs.flatMap { boolValue(of: "negated", in: $0) } ?? false
        let matchType = matchingPairs.flatMap { stringValue(of: "match_type", in: $0) }
        let rawValue = pairs.first { $0.key == "value" }?.value

        if ruleType == "bucketed_into_experience_key" {
            return RuleCondition(
                key: ruleType,
                matchType: "",
                value: nil,
                negation: negated,
                statefulTarget: StatefulRuleTarget(
                    ruleType: ruleType,
                    targetExperienceKey: ruleValueString(rawValue) ?? ""
                )
            )
        }

        if keyValueRuleTypes.contains(ruleType) {
            let key = stringValue(of: "key", in: pairs) ?? ""
            return make(key: key, value: ruleValueString(rawValue), negated: negated, matchType: matchType)
        }

        // Coverage-boundary gate (code-review R1 / AC7 divergence probe): a `rule_type` NOT in the
        // named-family allowlist above — e.g. `bucketed_into_experience`, or any bd-d4p-deferred
        // family — is UNMAPPED in the typed switch too, so it must degrade fail-closed here as
        // well, rather than routing through `make(...)` with the leaf's real matching/value.
        guard namedFamilyRuleTypes.contains(ruleType) else {
            return degraded()
        }

        return make(key: ruleType, value: ruleValueString(rawValue), negated: negated, matchType: matchType)
    }

    /// Converts a leaf's raw `value` member to the `String?` ``RuleCondition/value`` needs,
    /// matching the typed path's per-type stringification (a JSON string passes through as-is; a
    /// JSON bool/number stringifies via `String(_:)`, exactly as the typed numeric/bool
    /// extractors' `.map { String($0) }` do).
    private static func ruleValueString(_ value: JSONValue?) -> String? {
        switch value {
        case let .string(text)?:
            return text
        case let .bool(flag)?:
            return String(flag)
        case let .number(number)?:
            return String(number)
        default:
            return nil
        }
    }

    /// The `String` value of the `name`-keyed member in a `JSONValue.object`'s pairs, or `nil`
    /// when absent or not a JSON string.
    private static func stringValue(of name: String, in pairs: [JSONValue.Pair]) -> String? {
        guard case let .string(value)? = pairs.first(where: { $0.key == name })?.value else {
            return nil
        }
        return value
    }

    /// The `Bool` value of the `name`-keyed member in a `JSONValue.object`'s pairs, or `nil` when
    /// absent or not a JSON bool.
    private static func boolValue(of name: String, in pairs: [JSONValue.Pair]) -> Bool? {
        guard case let .bool(value)? = pairs.first(where: { $0.key == name })?.value else {
            return nil
        }
        return value
    }

    /// The array-typed member `name` in a `JSONValue.object`'s pairs, or `nil` when absent or not
    /// a JSON array.
    private static func arrayValue(of name: String, in pairs: [JSONValue.Pair]) -> [JSONValue]? {
        guard case let .array(value)? = pairs.first(where: { $0.key == name })?.value else {
            return nil
        }
        return value
    }

    /// The object-typed member `name`'s pairs in a `JSONValue.object`'s pairs, or `nil` when
    /// absent or not a JSON object.
    private static func objectPairs(of name: String, in pairs: [JSONValue.Pair]) -> [JSONValue.Pair]? {
        guard case let .object(value)? = pairs.first(where: { $0.key == name })?.value else {
            return nil
        }
        return value
    }
}
