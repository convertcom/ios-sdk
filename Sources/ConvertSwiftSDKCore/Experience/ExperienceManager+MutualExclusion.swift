// ExperienceManager+MutualExclusion.swift
// The degraded-audience rule extraction for IOS-3 (M2 integration, iOS mutual-exclusion qs-03).
// Split into its OWN file purely to keep `ExperienceManager.swift` under SwiftLint's
// `file_length` gate — mirrors the `ProjectConfig+AudienceDecoding.swift` /
// `RuleAdapter+JSONSentinelFlatten.swift` split precedent (IOS-1/IOS-2): a fresh file for a
// small, cohesive helper rather than growing an already-large one. `internal` (not `private`),
// since it is called from `ExperienceManager.audiencePasses(_:in:attributes:storeKey:)` in the
// sibling file — `private` is file-scoped in Swift and would not be reachable across files.
//
// Foundation-only — pure mapping over a decoded `JSONValue`; no platform framework, no state.

import Foundation

extension ExperienceManager {
    /// Extracts the `"rules"` sub-tree from a degraded audience's sentinel-captured payload (the
    /// FULL `ConfigAudience` JSON object — id/key/name/rules, per ``ProjectConfig
    /// /degradedAudienceSentinels``) and flattens it via ``RuleAdapter/flatten(_:)`` (the
    /// `JSONValue` overload, IOS-2). A non-object payload, or one whose `"rules"` member is absent
    /// or malformed, degrades to no groups — fail-closed, same as the typed path's `nil`-`rules`
    /// guard in ``audiencePasses(_:in:attributes:storeKey:)``.
    static func flattenDegradedAudienceRules(_ sentinelPayload: JSONValue) -> [RuleGroup] {
        guard case let .object(pairs) = sentinelPayload,
              let rulesValue = pairs.first(where: { $0.key == "rules" })?.value else {
            return []
        }
        return RuleAdapter.flatten(rulesValue)
    }
}
