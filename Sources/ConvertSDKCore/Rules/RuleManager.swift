// RuleManager.swift
// OR-of-AND rule-set evaluator for audience / location matching (Epic 3 / Story 3).
//
// PARITY NOTE — JavaScript SDK is ground truth. The boolean structure mirrors the LIVE
// `javascript-sdk/packages/rules/src/rule-manager.ts` (verified). The live JS is three
// levels (OR → AND → OR_WHEN → item); this story collapses it to a FLAT two-level model
// (`[RuleGroup]` outer-OR of `RuleGroup { conditions }` inner-AND) per the story tasks —
// Story 3.4 adapts the generated 3-level `RuleObjectAudience` graph into this flat model.
//
// FAIL-CLOSED (AC3): both empty-collection cases return `false` AND log a WARN — an empty
// outer rule set and an empty AND group. Eligibility is NEVER vacuous-true.
//
// ABSENT-KEY (AC2): `attributes[condition.key]` is `String?` (nil when the key is absent).
// The nil flows straight into `Comparisons.evaluate` for EVERY operator — `RuleManager`
// never short-circuits on a missing key, because `exists` / `doesNotExist` rely on nil
// reaching the comparator to compute presence.
//
// Foundation-only: a stateless `struct` whose only stored property is a `Sendable` ``Logger``
// is itself `Sendable` — no actor isolation needed.

import Foundation

/// Evaluates a flat OR-of-AND rule set against a data map of attributes.
///
/// Attribute-set-agnostic: the SAME evaluator runs an audience group against visitor
/// attributes and a location group against location props — `ExperienceManager` (Story 3.4)
/// composes the two calls with an AND. Stateless apart from the injected ``Logger``.
internal struct RuleManager {
    /// Sink for the WARN lines emitted on the two fail-closed empty-collection paths.
    private let logger: Logger

    /// - Parameter logger: Sink for the fail-closed WARN lines (empty outer set / empty group).
    init(logger: Logger) {
        self.logger = logger
    }

    /// Evaluates the rule set as an OR of AND-groups.
    ///
    /// - Parameters:
    ///   - rules: The outer OR — the set passes if ANY group passes. Empty → `false` + WARN.
    ///   - attributes: The data map each condition's `key` is resolved against.
    /// - Returns: `true` on the first passing group; `false` if none pass or the set is empty.
    func evaluate(rules: [RuleGroup], against attributes: [String: String]) -> Bool {
        guard !rules.isEmpty else {
            logger.log(
                level: .warn,
                type: "RuleManager",
                method: "evaluate",
                message: "empty rule set, returning false"
            )
            return false
        }
        return rules.contains { group in
            evaluate(group: group, against: attributes)
        }
    }

    /// Evaluates one AND-group: passes only if ALL conditions pass (short-circuits on the
    /// first failing condition). Empty group → `false` + WARN (fail-closed, AC3).
    private func evaluate(group: RuleGroup, against attributes: [String: String]) -> Bool {
        guard !group.conditions.isEmpty else {
            logger.log(
                level: .warn,
                type: "RuleManager",
                method: "evaluate",
                message: "empty AND group, returning false"
            )
            return false
        }
        return group.conditions.allSatisfy { condition in
            evaluate(condition: condition, against: attributes)
        }
    }

    /// Evaluates one leaf condition by dispatching to ``Comparisons``. The attribute lookup is
    /// an optional (nil when the key is absent); that optional flows straight through for EVERY
    /// operator — there is NO short-circuit on a missing key (AC2), because exists/doesNotExist
    /// compute presence from the nil itself.
    private func evaluate(condition: RuleCondition, against attributes: [String: String]) -> Bool {
        let value = attributes[condition.key]
        return Comparisons.evaluate(
            matchType: condition.matchType,
            value: value,
            testAgainst: condition.value,
            negated: condition.negation,
            logger: logger
        )
    }
}
