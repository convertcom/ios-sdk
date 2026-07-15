// Tests/ConvertSwiftSDKCoreTests/Support/MutualExclusionFixtures.swift
// Shared `ProjectConfig` / JSON builders for the mutual-exclusion end-to-end suite
// (IOS-3, qs-03 mobile mutual-exclusion). Spec of record:
//   _bmad-output/planning-artifacts/2026-06-09-convert-ios-sdk/qs-03-mutual-exclusion-rule.md
//
// ── Why a SEPARATE file from `ProjectConfigFixtures.swift` ────────────────────────────────
// `ProjectConfigFixtures.swift` is already 369 lines — appending here would push it toward
// SwiftLint's `file_length` gate. Mirrors the `ProjectConfig+AudienceDecoding.swift` /
// `RuleAdapter+JSONSentinelFlatten.swift` split precedent (IOS-1/IOS-2): a fresh file for a
// cohesive, self-contained set of builders rather than growing an already-large one.
// `ProjectConfigFixtures.experienceJSON` / `.makeConfig` (both plain `static func`, no `private`,
// so module-visible) are REUSED, not re-derived.
//
// ── What this builds ───────────────────────────────────────────────────────────────────────
// A DEGRADED audience (IOS-1: its `rules` tree embeds the unrecognised
// `bucketed_into_experience_key` `rule_type`, so the whole audience fails the generated typed
// decode and is retained as a placeholder + sentinel-captured raw JSON in
// `ProjectConfig.degradedAudienceSentinels`) attached to a SECOND experience — combined, per
// test, with a generic `country` leaf either under ONE AND-block (ALL) or as a separate OR-group
// (ANY), reusing the SAME leaf-JSON literals `MutualExclusionRuleAdapterJSONFlattenTests` (IOS-2)
// already proved decode/flatten correctly.

import Foundation
@testable import ConvertSwiftSDKCore

/// Pure namespace (mirrors `ProjectConfigFixtures`) — every member is `static`.
enum MutualExclusionFixtures {

    /// The `bucketed_into_experience_key` leaf JSON targeting `targetExperienceKey`, with
    /// `matching.negated` set per `negated`. This `rule_type` is NOT in the generated
    /// `RuleElementAudience` oneOf (IOS-1), so any audience embedding it degrades to a
    /// sentinel-captured placeholder at decode — never a typed `RuleObjectAudience`.
    static func statefulLeafJSON(targetExperienceKey: String, negated: Bool) -> String {
        """
        {"rule_type":"bucketed_into_experience_key","value":"\(targetExperienceKey)",\
        "matching":{"match_type":"equals","negated":\(negated)}}
        """
    }

    /// A generic `country == equals` leaf — the SAME known shape `ProjectConfigFixtures
    /// .audienceJSON` already proves round-trips through `RuleAdapter`/`Comparisons`.
    static func countryLeafJSON(equals: String) -> String {
        """
        {"rule_type":"country","value":"\(equals)","matching":{"match_type":"equals"}}
        """
    }

    /// ONE AND-block ("ALL" — every leaf in `leavesJSON` must pass together), wrapped in the sole
    /// outer OR entry. Mirrors `MutualExclusionRuleAdapterJSONFlattenTests.makeSentinelRuleTree`'s
    /// envelope shape.
    static func allOfRulesJSON(_ leavesJSON: [String]) -> String {
        "{\"OR\":[{\"AND\":[{\"OR_WHEN\":[" + leavesJSON.joined(separator: ",") + "]}]}]}"
    }

    /// TWO SEPARATE AND-blocks, one per entry in `groupLeavesJSON` ("ANY" — the audience passes
    /// if any group passes), each holding exactly the one leaf supplied for that group.
    static func anyOfRulesJSON(_ groupLeavesJSON: [String]) -> String {
        let blocks = groupLeavesJSON.map { "{\"AND\":[{\"OR_WHEN\":[\($0)]}]}" }
        return "{\"OR\":[" + blocks.joined(separator: ",") + "]}"
    }

    /// A `ConfigAudience` JSON object whose `rules` is the caller-supplied tree. Carrying the
    /// stateful leaf (directly, or alongside a generic sibling) makes this audience degrade to a
    /// sentinel-captured placeholder at decode (IOS-1) — a real read-only resolver
    /// (IOS-3) is what would read the leaf back via `RuleAdapter.flatten(_ sentinelRuleTree:)`
    /// (IOS-2) off `ProjectConfig.degradedAudienceSentinels[id]`'s `"rules"` member.
    static func degradedAudienceJSON(id: String, key: String, rulesJSON: String) -> String {
        """
        {"id":"\(id)","key":"\(key)","type":"transient","rules":\(rulesJSON)}
        """
    }

    /// A two-experience `ProjectConfig`: `expAKey` (always buckets, no gates — the mutual-exclusion
    /// TARGET) and `expBKey` (gated on ONE degraded audience carrying `audienceRulesJSON` — the
    /// experience carrying the exclusion rule). Mirrors qs-03's inline fixture context (`exp-a`,
    /// `exp-b`, both always-active, sole full-traffic variation) with test-local ids/keys.
    ///
    /// - Parameters:
    ///   - expAId: `exp-a`'s wire `id` (what the bucketing map is keyed on — iOS is id-keyed).
    ///   - expAKey: `exp-a`'s wire `key` (what a `bucketed_into_experience_key` rule's `value`
    ///     targets, and what `fullExperience(forKey:)` resolves).
    ///   - expBId / expBKey / expBVariationId: mirror the above for the gated experience.
    ///   - audienceId: the degraded audience's wire `id`, referenced from `exp-b`'s `audiences`.
    ///   - audienceRulesJSON: the audience's `rules` tree body (built via ``allOfRulesJSON(_:)`` /
    ///     ``anyOfRulesJSON(_:)`` over ``statefulLeafJSON(targetExperienceKey:negated:)`` /
    ///     ``countryLeafJSON(equals:)``).
    static func twoExperienceMutualExclusionConfig(
        expAId: String = "id-a",
        expAKey: String = "exp-a",
        expAVariationId: String = "var-a",
        expBId: String = "id-b",
        expBKey: String = "exp-b",
        expBVariationId: String = "var-b",
        audienceId: String = "aud-me",
        audienceRulesJSON: String
    ) throws -> ProjectConfig {
        let experienceA = ProjectConfigFixtures.experienceJSON(
            id: expAId, key: expAKey, variationId: expAVariationId, variationKey: "control-a", alloc: 100
        )
        let experienceB = ProjectConfigFixtures.experienceJSON(
            id: expBId, key: expBKey, variationId: expBVariationId, variationKey: "control-b", alloc: 100,
            audiences: [audienceId]
        )
        let audience = degradedAudienceJSON(
            id: audienceId, key: "\(audienceId)-key", rulesJSON: audienceRulesJSON
        )
        return try ProjectConfigFixtures.makeConfig(
            experiencesJSON: "[\(experienceA),\(experienceB)]",
            audiencesJSON: "[\(audience)]"
        )
    }
}
