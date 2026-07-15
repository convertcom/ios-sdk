// StatefulRuleTarget.swift
// The stateful-leaf payload for a `bucketed_into_experience_key` rule condition (IOS-2, qs-03
// mobile mutual-exclusion). Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// Carries the target-experience-KEY payload of a STATEFUL rule leaf (today only
/// `bucketed_into_experience_key`). Unlike every other ``RuleCondition`` leaf, this one is
/// resolved not by looking `key` up in `attributes` and dispatching through ``Comparisons``, but
/// by querying an injected bucketing-decision resolver
/// (`RuleManager.evaluate(rules:against:resolvingBucketedIntoExperienceKey:)`) — see qs-03.
internal struct StatefulRuleTarget: Sendable, Equatable {
    /// The wire `rule_type` discriminator (today always `"bucketed_into_experience_key"`) —
    /// carried as a forward-compat marker in case a sibling stateful rule type is added later.
    let ruleType: String
    /// The TARGET EXPERIENCE KEY (`rule.value`) — a KEY, not an id. iOS is id-keyed internally;
    /// resolving this key to an id (and then to a bucketing decision) is the resolver's job
    /// (IOS-3), not this type's.
    let targetExperienceKey: String
}
