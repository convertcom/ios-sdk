// PreviewDecision.swift
// Pure forced-variation decision primitive for experiment preview (qs-02 Experiment Preview,
// contract §2 "Decision" clause / AC4 / AC5), task IOS-3. Foundation-only — part of the
// pure-logic ConvertSwiftSDKCore target.
//
// SCOPE (IOS-3 — narrower than the full qs-02 preview surface): this primitive matches a
// `variationId` against one already-resolved `Components.Schemas.ConfigExperience` and nothing
// else. It takes no `visitorId`, no attributes/environment/locationProperties, and no
// decision-store input — so audiences, segments, locations, the environment check, experience
// status, variation status/traffic filters, stored decisions, and the bucketing hash are all
// bypassed BY CONSTRUCTION: there is no reachable input for a rule gate, a bucketing walk, or a
// sticky-decision lookup to consult. Neither `BucketingManager` nor
// `ExperienceManager.selectVariation` is called or reachable from this signature.

import Foundation

/// Resolves a forced-variation decision for experiment preview, bypassing bucketing, rule
/// matching, and stored decisions entirely.
public enum PreviewDecision {

    /// Matches `variationId` against `experience.variations` and returns the corresponding
    /// `Variation` unconditionally — never consulting experience status, environment, variation
    /// status/traffic, or any stored decision.
    ///
    /// Field mapping mirrors the `Variation` shape `BucketingManager.bucket`/
    /// `bucketVersionGated` build from a normal bucketed decision
    /// (`Sources/ConvertSwiftSDKCore/Bucketing/BucketingManager.swift:118-123`, `:205-210`):
    /// optional `id`/`key` fields degrade to `""` rather than being force-unwrapped.
    ///
    /// - Parameters:
    ///   - experience: the experience config to match `variationId` against.
    ///   - variationId: the id of the variation to force.
    /// - Returns: the forced `Variation`, or `nil` when `variationId` is not present in
    ///   `experience.variations` (inert-on-bad-input signal). Never logs, never throws.
    public static func forcedVariation(
        for experience: Components.Schemas.ConfigExperience,
        variationId: String
    ) -> Variation? {
        guard let matched = experience.variations?.first(where: { $0.id == variationId }) else {
            return nil
        }
        return Variation(
            id: matched.id ?? "",
            key: matched.key ?? "",
            experienceId: experience.id ?? "",
            experienceKey: experience.key ?? ""
        )
    }
}
