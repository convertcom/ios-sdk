// ExperienceManager+MutualExclusion.swift
// The degraded-audience rule extraction (IOS-3, M2 integration, iOS mutual-exclusion qs-03) and
// the whole-audience-override DETECTION helpers (M2, iOS mutual-exclusion qs-04
// re-architecture). Split into its OWN file purely to keep `ExperienceManager.swift` under
// SwiftLint's `file_length` gate — mirrors the `ProjectConfig+AudienceDecoding.swift` /
// `RuleAdapter+JSONSentinelFlatten.swift` split precedent (IOS-1/IOS-2): a fresh file for a
// small, cohesive helper rather than growing an already-large one. `internal` (not `private`),
// since these are called from `ExperienceManager.audiencePasses(_:in:attributes:storeKey:)` in
// the sibling file — `private` is file-scoped in Swift and would not be reachable across files.
//
// Foundation-only — pure mapping over decoded `JSONValue`/`RuleGroup` values; no platform
// framework, no state.

import Foundation

extension ExperienceManager {
    /// Extracts the `"rules"` sub-tree from a degraded audience's sentinel-captured payload (the
    /// FULL `ConfigAudience` JSON object — id/key/name/rules, per ``ProjectConfig
    /// /degradedAudienceSentinels``) and flattens it via ``RuleAdapter/flatten(_:)`` (the
    /// `JSONValue` overload, IOS-2). A non-object payload, or one whose `"rules"` member is absent
    /// or malformed, degrades to no groups — fail-closed, same as the typed path's `nil`-`rules`
    /// guard in ``flattenedGroups(for:in:)``.
    static func flattenDegradedAudienceRules(_ sentinelPayload: JSONValue) -> [RuleGroup] {
        guard case let .object(pairs) = sentinelPayload,
              let rulesValue = pairs.first(where: { $0.key == "rules" })?.value else {
            return []
        }
        return RuleAdapter.flatten(rulesValue)
    }

    /// Flattens ONE attached audience's rule tree into `[RuleGroup]`, dispatching to the
    /// DEGRADED sentinel path (``flattenDegradedAudienceRules(_:)``) when the audience's typed
    /// decode degraded (its tree embedded an unrecognised `rule_type` leaf, e.g.
    /// `bucketed_into_experience_key` — IOS-1), or the typed ``RuleAdapter/flatten(_:)`` path
    /// otherwise — the ONLY dispatch difference; a normally-decoded audience's typed
    /// `rules?.value1` is still flattened exactly as before (bit-identical, AC7). An absent
    /// typed `rules` on a NON-degraded audience yields no groups (fail-closed).
    static func flattenedGroups(
        for audience: Components.Schemas.ConfigAudience,
        in config: ProjectConfig
    ) -> [RuleGroup] {
        if let id = audience.id, let sentinel = config.degradedAudienceSentinels?[id] {
            return flattenDegradedAudienceRules(sentinel)
        }
        guard let rules = audience.rules?.value1 else { return [] }
        return RuleAdapter.flatten(rules)
    }

    /// Finds the first STATEFUL leaf (`bucketed_into_experience_key`) in an already-flattened
    /// audience's groups, if any (M2, iOS mutual-exclusion qs-04 re-architecture). An audience
    /// carrying one is a whole-audience EXCLUSION audience whose ENTIRE match is resolved via
    /// ``BucketingExclusion/resolve(targetExperienceKey:negated:resolver:logger:)`` alone —
    /// mirroring JS's `_isBucketingExclusionRule` (`data-manager.ts:1246-1265`), which likewise
    /// walks the WHOLE audience tree for the first such leaf and, if found, never evaluates any
    /// sibling leaf in the same tree through the generic engine. Returns `nil` for a generic
    /// (non-stateful) audience, however many groups/conditions it carries.
    static func statefulLeaf(
        in groups: [RuleGroup]
    ) -> (targetExperienceKey: String, negated: Bool)? {
        for group in groups {
            for condition in group.conditions {
                if let target = condition.statefulTarget {
                    return (target.targetExperienceKey, condition.negation)
                }
            }
        }
        return nil
    }
}
