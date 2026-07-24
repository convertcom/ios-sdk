// BucketingExclusion.swift
// The whole-audience-override resolution seam for a `bucketed_into_experience_key`
// mutual-exclusion rule (M2, iOS mutual-exclusion qs-04 re-architecture).
//
// PARITY NOTE — mirrors the LIVE JS `_resolveBucketingExclusion`
// (`javascript-sdk/packages/data/src/data-manager.ts:1282-1304`, `feat/mutual-exclusion-rule`)
// almost verbatim: `bucketedRaw = resolver(targetExperienceKey)` (`nil` == unknown target ->
// WARN naming the key, default `bucketedRaw = false`; a resolver-returned `false` == a KNOWN
// target the visitor is simply not bucketed into -> NO warn); `matched = negated ? !bucketedRaw
// : bucketedRaw`, applied exactly once.
//
// This seam is RuleManager-INDEPENDENT by design (see the sibling
// `Tests/ConvertSwiftSDKCoreTests/Rules/MutualExclusionRuleManagerTests.swift` header for the
// full rework rationale): a whole audience whose tree carries this leaf resolves its ENTIRE
// match through this seam alone — sibling leaves in the same tree are never evaluated by any
// engine — mirroring JS's `filterMatchedRecordsWithRule` (`data-manager.ts:1336-1345`), which
// never calls the generic `isRuleMatched` for an exclusion audience.
//
// Foundation-only — a stateless `enum` namespace; no platform framework, no state.

import Foundation

/// Resolves a `bucketed_into_experience_key` whole-audience-override rule leaf.
///
/// `resolver(key)` returns `Bool?`: `true` (the visitor is bucketed into the target), `false`
/// (a KNOWN target the visitor is simply not bucketed into — no warning), or `nil` (an unknown
/// target — WARNs naming the key, defaults to not-bucketed).
internal enum BucketingExclusion {
    /// - Parameters:
    ///   - targetExperienceKey: The rule's `value` — the target experience KEY (not id).
    ///   - negated: The leaf's `matching.negated` flag, applied to `bucketedRaw` exactly once.
    ///   - resolver: Queried once for `targetExperienceKey`; `nil` means an unknown target.
    ///   - logger: Sink for the WARN line emitted only when `resolver` returns `nil`.
    /// - Returns: `negated ? !bucketedRaw : bucketedRaw`, where `bucketedRaw` is the resolver's
    ///   result (defaulting to `false` for an unknown target).
    static func resolve(
        targetExperienceKey: String,
        negated: Bool,
        resolver: (String) -> Bool?,
        logger: Logger
    ) -> Bool {
        let bucketedRaw: Bool
        if let resolved = resolver(targetExperienceKey) {
            bucketedRaw = resolved
        } else {
            logger.log(
                level: .warn,
                type: "BucketingExclusion",
                method: "resolve",
                message: "bucketed_into_experience_key: unknown target experience key "
                    + "'\(targetExperienceKey)', treating as not bucketed"
            )
            bucketedRaw = false
        }
        return negated ? !bucketedRaw : bucketedRaw
    }
}
