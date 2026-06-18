// RuleGroup.swift
// One AND block in a rule set: all conditions must pass for the group to pass.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// One AND block: all conditions must pass for the group to pass. A `[RuleGroup]` is the
/// outer OR — the set passes if ANY group passes. Flat hand-written model for Story 3.3.
internal struct RuleGroup: Sendable, Equatable {
    /// The leaf comparisons ANDed together; an empty array fails closed (returns false).
    let conditions: [RuleCondition]
}
