// RuleCondition.swift
// One leaf comparison in a rule group.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// One leaf comparison in a rule group. `key` is the attribute name looked up on the
/// data map; `matchType` is the wire operator string; `value` is the rule's test value
/// (the `testAgainst` side); `negation` inverts the result. Flat hand-written model for
/// Story 3.3 — Story 3.4 adapts the generated 3-level RuleObjectAudience/RuleObject into this.
internal struct RuleCondition: Sendable, Equatable {
    /// Attribute name resolved against the visitor / location data map.
    let key: String
    /// Wire operator string dispatched through ``Comparisons`` (e.g. `"equals"`, `"isIn"`).
    let matchType: String
    /// The rule's test value — the `testAgainst` side of the comparison; `nil` when absent.
    let value: String?
    /// When `true`, inverts the comparator's result.
    let negation: Bool
}
