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
    /// Non-nil for a STATEFUL leaf (today only `bucketed_into_experience_key`, IOS-2 / qs-03
    /// mobile mutual-exclusion): the leaf is resolved by ``RuleManager`` against an injected
    /// bucketing-decision resolver instead of `attributes[key]` -> ``Comparisons``. `nil` for
    /// every generic (attribute-lookup) leaf — additive/defaulted so every pre-existing 4-arg
    /// call site keeps compiling unchanged.
    let statefulTarget: StatefulRuleTarget?

    /// Explicit initializer (NOT the synthesized memberwise init): a `let` stored property with
    /// an `= nil` default is NOT overridable through Swift's synthesized memberwise
    /// initializer — verified empirically (a defaulted `let` parameter is dropped from that
    /// init's signature entirely, so passing it explicitly fails to compile with "extra
    /// argument"). A hand-written `init` with a default PARAMETER value has no such
    /// restriction: it both omits cleanly (existing 4-arg call sites) and accepts an explicit
    /// override (the stateful call sites in `RuleAdapter`/tests).
    init(key: String, matchType: String, value: String?, negation: Bool, statefulTarget: StatefulRuleTarget? = nil) {
        self.key = key
        self.matchType = matchType
        self.value = value
        self.negation = negation
        self.statefulTarget = statefulTarget
    }
}
