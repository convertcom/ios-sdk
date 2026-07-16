// Tests/ConvertSwiftSDKCoreTests/Support/MutualExclusionFixtures.swift
// Shared `ProjectConfig` / JSON builders for the mutual-exclusion end-to-end suite
// (M2, iOS mutual-exclusion qs-04). Spec of record:
//   _bmad-output/implementation-artifacts/2026-06-09-convert-ios-sdk/qs-04-mutual-exclusion-rule.md
//
// ── Why a SEPARATE file from `ProjectConfigFixtures.swift` ────────────────────────────────
// `ProjectConfigFixtures.swift` is already ~370 lines — appending here would push it toward
// SwiftLint's `file_length` gate. Mirrors the `ProjectConfig+AudienceDecoding.swift` /
// `RuleAdapter+JSONSentinelFlatten.swift` split precedent: a fresh file for a cohesive,
// self-contained set of builders rather than growing an already-large one.
// `ProjectConfigFixtures.experienceJSON` / `.makeConfig` (both plain `static func`, no `private`,
// so module-visible) are REUSED, not re-derived; ditto `ProjectConfigFixtures.audienceJSON` for the
// generic (`country`) audience half of the two-audience fixture below.
//
// ── RE-ARCHITECTURE (this file) — JS parity over the mixed-single-audience shape ──────────────
// The JS reference (`javascript-sdk/packages/data/src/data-manager.ts`, `feat/mutual-exclusion-rule`)
// resolves mutual exclusion at the WHOLE-AUDIENCE level: `_isBucketingExclusionRule` (:1246-1265)
// walks ONE audience's OR→AND→OR_WHEN tree for ANY `bucketed_into_experience_key` leaf; if found, the
// ENTIRE audience is an EXCLUSION audience and `filterMatchedRecordsWithRule` (:1336-1345) resolves its
// match via `_resolveBucketingExclusion` (:1282-1304) ALONE — sibling leaves in the SAME audience tree
// are NEVER evaluated. Cross-audience `ALL`/`ANY` combination (:418-442) then composes PER-AUDIENCE
// match booleans via `experience.settings.matching_options.audiences`.
//
// The PRIOR iOS fixture shape (`allOfRulesJSON`/`anyOfRulesJSON`, now REMOVED) built ONE audience whose
// rule tree mixed a stateful leaf with a generic sibling leaf, combined via ordinary AND/OR — that
// shape does not correspond to any real JS code path (a mixed exclusion-audience tree never reaches
// the generic engine at all; its sibling leaves are ignored by `_resolveBucketingExclusion`). This
// file now builds the JS-faithful TWO-AUDIENCE shape instead: one DEDICATED exclusion audience (the
// stateful leaf ALONE) and one separate GENERIC audience, composed via the experience's
// `settings.matching_options.audiences` (`ALL`/`ANY`) — see `twoAudienceMutualExclusionConfig(_:)`.
//
// ── What the single-audience builders below still build ───────────────────────────────────
// A DEGRADED audience (its `rules` tree embeds the unrecognised `bucketed_into_experience_key`
// `rule_type`, so the whole audience fails the generated typed decode and is retained as a
// placeholder + sentinel-captured raw JSON in `ProjectConfig.degradedAudienceSentinels`) attached to a
// SECOND experience — used by the pure-exclusion (AC2/AC3/AC5/AC8) scenarios, where the audience
// carries ONLY the stateful leaf (`singleLeafRulesJSON(_:)`).

import Foundation
@testable import ConvertSwiftSDKCore

/// Pure namespace (mirrors `ProjectConfigFixtures`) — every member is `static`.
enum MutualExclusionFixtures {

    /// The `bucketed_into_experience_key` leaf JSON targeting `targetExperienceKey`, with
    /// `matching.negated` set per `negated`. This `rule_type` is NOT in the generated
    /// `RuleElementAudience` oneOf, so any audience embedding it degrades to a sentinel-captured
    /// placeholder at decode — never a typed `RuleObjectAudience`.
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

    /// Wraps ONE leaf JSON literal in the sole `OR → AND → OR_WHEN` envelope — the wire shape a
    /// DEDICATED single-rule audience carries (JS `_isBucketingExclusionRule`'s whole-audience
    /// exclusion shape: an audience whose ENTIRE tree is the one stateful leaf, no sibling). Distinct
    /// from the removed `allOfRulesJSON`/`anyOfRulesJSON` (which combined MULTIPLE leaves within ONE
    /// audience's tree — the mixed-single-audience shape this rework replaces with two SEPARATE
    /// audiences composed via `matching_options`, see `twoAudienceMutualExclusionConfig(_:)`).
    static func singleLeafRulesJSON(_ leafJSON: String) -> String {
        "{\"OR\":[{\"AND\":[{\"OR_WHEN\":[\(leafJSON)]}]}]}"
    }

    /// A `ConfigAudience` JSON object whose `rules` is the caller-supplied tree. Carrying the
    /// stateful leaf makes this audience degrade to a sentinel-captured placeholder at decode — a
    /// real read-only resolver reads the leaf back off `ProjectConfig.degradedAudienceSentinels[id]`'s
    /// `"rules"` member.
    static func degradedAudienceJSON(id: String, key: String, rulesJSON: String) -> String {
        """
        {"id":"\(id)","key":"\(key)","type":"transient","rules":\(rulesJSON)}
        """
    }

    /// A two-experience `ProjectConfig`: `expAKey` (always buckets, no gates — the mutual-exclusion
    /// TARGET) and `expBKey` (gated on ONE degraded audience carrying `audienceRulesJSON` — the
    /// experience carrying the exclusion rule ALONE, no generic sibling). Mirrors qs-04's inline
    /// fixture context (`exp-a`, `exp-b`, both always-active, sole full-traffic variation) with
    /// test-local ids/keys. `audienceRulesJSON` is expected to come from
    /// ``singleLeafRulesJSON(_:)`` over ``statefulLeafJSON(targetExperienceKey:negated:)`` (a PURE
    /// exclusion audience — no `ALL`/`ANY` combination question arises with a single audience).
    ///
    /// - Parameters:
    ///   - expAId: `exp-a`'s wire `id` (what the bucketing map is keyed on — iOS is id-keyed).
    ///   - expAKey: `exp-a`'s wire `key` (what a `bucketed_into_experience_key` rule's `value`
    ///     targets, and what `fullExperience(forKey:)` resolves).
    ///   - expBId / expBKey / expBVariationId: mirror the above for the gated experience.
    ///   - audienceId: the degraded audience's wire `id`, referenced from `exp-b`'s `audiences`.
    ///   - audienceRulesJSON: the audience's `rules` tree body.
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

    /// A two-experience, TWO-AUDIENCE `ProjectConfig` mirroring JS's real composition shape (spec
    /// verified fact: "Fullstack audiences are transient; `matching_options.audiences` supports
    /// `ALL`/`ANY`"; JS `matchRulesByField`, `data-manager.ts:419-428`): `expBKey` is gated on TWO
    /// SEPARATE attached audiences —
    ///   (a) a DEDICATED exclusion audience (`exclusionAudienceId`) whose tree is ONLY the negated
    ///       `bucketed_into_experience_key` leaf targeting `exclusionTargetKey` (no generic sibling —
    ///       JS's `_resolveBucketingExclusion` never sees one anyway), and
    ///   (b) a GENERIC audience (`genericAudienceId`) carrying a `country == genericCountryEquals`
    ///       leaf (`ProjectConfigFixtures.audienceJSON`, reused verbatim — no new leaf shape) —
    /// composed via `expBKey`'s `settings.matching_options.audiences = matchingOptions` (`"all"` /
    /// `"any"`, the raw `GenericListMatchingOptions` wire value).
    ///
    /// - Parameters:
    ///   - expAId/expAKey/expAVariationId: the mutual-exclusion TARGET experience (always buckets,
    ///     no gates).
    ///   - expBId/expBKey/expBVariationId: the gated experience carrying both audiences.
    ///   - exclusionAudienceId/exclusionTargetKey/exclusionNegated: the dedicated exclusion audience's
    ///     id and its lone leaf's target key / `negated` flag.
    ///   - genericAudienceId/genericCountryEquals: the generic audience's id and its `country` leaf's
    ///     match value.
    ///   - matchingOptions: the raw `settings.matching_options.audiences` wire value (`"all"` /
    ///     `"any"`) `expBKey` emits.
    static func twoAudienceMutualExclusionConfig(
        expAId: String = "id-a",
        expAKey: String = "exp-a",
        expAVariationId: String = "var-a",
        expBId: String = "id-b",
        expBKey: String = "exp-b",
        expBVariationId: String = "var-b",
        exclusionAudienceId: String = "aud-excl",
        exclusionTargetKey: String = "exp-a",
        exclusionNegated: Bool = true,
        genericAudienceId: String = "aud-generic",
        genericCountryEquals: String = "US",
        matchingOptions: String
    ) throws -> ProjectConfig {
        let experienceA = ProjectConfigFixtures.experienceJSON(
            id: expAId, key: expAKey, variationId: expAVariationId, variationKey: "control-a", alloc: 100
        )
        let experienceB = ProjectConfigFixtures.experienceJSON(
            id: expBId, key: expBKey, variationId: expBVariationId, variationKey: "control-b", alloc: 100,
            audiences: [exclusionAudienceId, genericAudienceId],
            matchingOptionsAudiences: matchingOptions
        )
        let exclusionAudience = degradedAudienceJSON(
            id: exclusionAudienceId,
            key: "\(exclusionAudienceId)-key",
            rulesJSON: singleLeafRulesJSON(
                statefulLeafJSON(targetExperienceKey: exclusionTargetKey, negated: exclusionNegated)
            )
        )
        let genericAudience = ProjectConfigFixtures.audienceJSON(
            id: genericAudienceId, key: "\(genericAudienceId)-key", countryEquals: genericCountryEquals
        )
        return try ProjectConfigFixtures.makeConfig(
            experiencesJSON: "[\(experienceA),\(experienceB)]",
            audiencesJSON: "[\(exclusionAudience),\(genericAudience)]"
        )
    }
}
