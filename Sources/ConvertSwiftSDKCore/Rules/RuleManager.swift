// RuleManager.swift
// OR-of-AND rule-set evaluator for audience / location matching (Epic 3 / Story 3).
//
// PARITY NOTE — the boolean structure (OR-of-AND over a flat two-level `[RuleGroup]` outer-OR
// of `RuleGroup { conditions }` inner-AND) is intended to mirror the LIVE JS
// `javascript-sdk/packages/rules/src/rule-manager.ts`'s three-level OR → AND → OR_WHEN → item
// walk collapsed per the Story 3.4 flattening. CAVEAT (recorded here rather than claimed as
// blanket-verified): the collapse is confirmed bit-identical to the live JS ONLY for the
// single-leaf `OR_WHEN` shape every fixture in this suite exercises; `RuleAdapter`'s
// AND(OR(leaves)) → AND(all leaves) collapse for a MULTI-leaf `OR_WHEN` block has not been
// checked against JS's OR_WHEN-is-an-OR semantics and is tracked as a known, separately-filed
// gap — beads issue `ai-driven-product-dev-iefd`. Out of scope here; not fixed by this file.
//
// FAIL-CLOSED (AC3): both empty-collection cases return `false` AND log a WARN — an empty
// outer rule set and an empty AND group. Eligibility is NEVER vacuous-true.
//
// ABSENT-KEY (AC2): `attributes[condition.key]` is `String?` (nil when the key is absent).
// The nil flows straight into `Comparisons.evaluate` for EVERY operator — `RuleManager`
// never short-circuits on a missing key, because `exists` / `doesNotExist` rely on nil
// reaching the comparator to compute presence.
//
// GENERIC-ONLY EVALUATOR (M2, iOS mutual-exclusion qs-04 re-architecture): `evaluate` no
// longer accepts a `resolvingBucketedIntoExperienceKey` resolver — a whole-audience
// `bucketed_into_experience_key` exclusion rule is now detected and resolved OUTSIDE this type,
// at the `ExperienceManager` audience layer, via the dedicated ``BucketingExclusion`` seam
// (mirrors JS's `_isBucketingExclusionRule` / `_resolveBucketingExclusion`, which likewise never
// route through the generic `isRuleMatched` engine for an exclusion audience). This evaluator
// therefore only ever sees generic (non-stateful) conditions again — see the sibling
// `Tests/ConvertSwiftSDKCoreTests/Rules/MutualExclusionRuleManagerTests.swift` header for the
// full rework rationale.
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

    /// Evaluates one leaf condition against `attributes`. The lookup is an optional (`nil`
    /// when the key is absent) that flows straight through for EVERY operator — there is NO
    /// short-circuit on a missing key (AC2), because exists/doesNotExist compute presence from
    /// the nil itself.
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
