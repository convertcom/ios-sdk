// Tests/ConvertSwiftSDKCoreTests/Rules/MutualExclusionRuleManagerTests.swift
//
// RED-phase suite for IOS-2 (M2 unit, iOS mutual-exclusion qs-03): `RuleManager.evaluate` learns to
// resolve a STATEFUL rule leaf (`bucketed_into_experience_key`) via an INJECTED, read-only
// three-state resolver `(targetExperienceKey) -> Bool?` instead of `attributes[key]` ->
// `Comparisons`. Spec of record:
//   _bmad-output/planning-artifacts/2026-06-09-convert-ios-sdk/qs-03-mutual-exclusion-rule.md
// Task/plan: work/2026-07-15-ios-sdk-mutual-exclusion/workflow-state.yaml (task IOS-2, "v18s").
//
// None of the symbols this file exercises exist in Sources/ yet:
//   - `RuleCondition.statefulTarget: StatefulRuleTarget?` (new additive field)
//   - `StatefulRuleTarget` (new type: `ruleType` + `targetExperienceKey`)
//   - `RuleManager.evaluate(rules:against:resolvingBucketedIntoExperienceKey:)` (new 3rd parameter)
// This file MUST fail to COMPILE ("value of type 'RuleCondition' has no member 'statefulTarget'" /
// "cannot find 'StatefulRuleTarget' in scope" / "extra argument 'resolvingBucketedIntoExperienceKey'
// in call") — that is the expected, correct RED state. Because `ConvertSwiftSDKCoreTests` is one SPM
// module/target, this compile failure fails `swift build`/`swift test` for the WHOLE target (every
// existing suite included) until the GREEN phase lands the symbols below — this is the same
// unavoidable, accepted RED shape as IOS-1's `RuleAdapterTests.swift` / `ProjectConfigTests.swift`
// headers ("RuleAdapter does NOT exist yet ... MUST fail to compile").
//
// ── ASSUMED SHAPES (spec-silent — qs-03 fixes the resolution ALGORITHM and the 8-row fixture, but
// not the Swift-level types/signatures; these are IOS-2 implementation choices, recorded here and in
// the sibling decision log for the decision_audit checkpoint) ──────────────────────────────────────
//
//   internal struct StatefulRuleTarget: Sendable, Equatable {
//       let ruleType: String              // e.g. "bucketed_into_experience_key" — forward-compat
//                                          // marker in case a sibling stateful rule type is added
//                                          // later; today always this one value.
//       let targetExperienceKey: String   // rule.value — the TARGET EXPERIENCE KEY, NOT an id.
//   }
//
//   internal struct RuleCondition: Sendable, Equatable {
//       let key: String
//       let matchType: String
//       let value: String?
//       let negation: Bool
//       let statefulTarget: StatefulRuleTarget? = nil   // ADDITIVE, defaulted — every existing
//                                                        // 4-arg `RuleCondition(key:matchType:
//                                                        // value:negation:)` call site (this suite's
//                                                        // own generic-condition helpers included,
//                                                        // plus every pre-existing RuleManagerTests /
//                                                        // RuleAdapterTests call site) keeps
//                                                        // compiling unchanged.
//   }
//
//   extension RuleManager {
//       func evaluate(
//           rules: [RuleGroup],
//           against attributes: [String: String],
//           resolvingBucketedIntoExperienceKey resolver: ((String) -> Bool?)? = nil
//       ) -> Bool
//   }
//
// Dispatch (per leaf, inside the existing private `evaluate(condition:against:)`): a NON-nil
// `condition.statefulTarget` bypasses `attributes[key]` -> `Comparisons` ENTIRELY (AC7 — the generic
// path must stay bit-identical, so the stateful branch cannot ride the same `Comparisons.evaluate`
// dispatch table, which has no "bucketed-into" comparator). Resolution:
//   bucketedRaw = resolver?(target.targetExperienceKey) ?? { warn(targetExperienceKey); return false }()
//   matched     = condition.negation ? !bucketedRaw : bucketedRaw
// A `nil` resolver return (target key not found in config — "unknown target") warns, NAMING the key,
// and treats `bucketedRaw` as `false`; a resolver returning `false` (a KNOWN target the visitor is
// simply not bucketed into) does NOT warn (AC8). Negation is applied to `bucketedRaw` (known or
// defaulted-false-on-unknown) exactly once, mirroring `Comparisons.applyNegation`'s placement after
// dispatch — this is why row 7 (`negated: true`, unknown target) resolves `matched: true`.
//
// Design choice: negation is NOT duplicated inside `StatefulRuleTarget` — `RuleCondition.negation`
// (the existing field) remains the single source of truth for every leaf, generic or stateful.
//
// Fixture: qs-03's inline 8-row table (spec lines 66-77). Config context: `exp-a` (id `100111`),
// `exp-b` (id `100222`) both exist; `exp-zz` does NOT (rows 6/7 — the resolver returns `nil` for it).
// At THIS (unit) level there is no real `DecisionStore`/`ExperienceManager` — the "stored bucketing
// map" column is simulated purely by the FAKE resolver's return value per row (a real config/storage
// resolver is IOS-3's job). Visitor `attributes` are ALWAYS passed empty (`[:]`) here, proving AC4
// ("zero new application inputs") structurally: the stateful branch cannot consult `attributes` at
// all — it has no `key` to look up.
//
// SonarQube `new_duplicated_lines_density` guard: ONE parameterized `@Test(arguments:)` drives all
// 8 rows from a single `fixtureRows` table + one shared `MutualExclusionFixtureRow` model — no
// per-row test-function duplication.

import Testing
@testable import ConvertSwiftSDKCore

@Suite("RuleManager mutual-exclusion (bucketed_into_experience_key) — IOS-2 RED")
struct MutualExclusionRuleManagerTests {

    // MARK: - Fixture row model (shared — SonarQube duplication guard)

    /// One row of the qs-03 inline 8-row fixture (spec lines 66-77), collapsed to the fields the
    /// UNIT-level resolver seam actually needs: the target key, the rule's `negated` flag, what the
    /// FAKE resolver returns for that key (`nil` == "unknown target"), and the expected outcomes.
    struct MutualExclusionFixtureRow: Sendable {
        /// The qs-03 spec's row number (1-8), carried through purely for readable failure messages.
        let rowNumber: Int
        /// `rule.value` — the target experience KEY the leaf names.
        let targetExperienceKey: String
        /// The leaf's `matching.negated` flag.
        let negation: Bool
        /// What the fake three-state resolver returns when queried for `targetExperienceKey`:
        /// `true` (bucketed), `false` (known target, not bucketed), or `nil` (unknown target).
        let resolverReturns: Bool?
        /// The qs-03 fixture's expected `matched` column.
        let expectedMatched: Bool
        /// Whether a `.warn` line naming `targetExperienceKey` must be logged (only rows 6/7 —
        /// `resolverReturns == nil`, an unknown target; AC8).
        let expectsWarning: Bool
    }

    /// The qs-03 8-row fixture (spec lines 68-77), verbatim. Row 8 is DELIBERATELY identical in
    /// resolver-stance/expectation to row 4 at THIS unit level — the spec's row-8 scenario ("present
    /// only in persisted storage, fresh SDK instance, warm files") is a cross-relaunch integration
    /// concern this seam cannot distinguish from row 4 without a real `DecisionStore`; that
    /// distinction is IOS-3's job (out of scope here, per the IOS-2 dispatch).
    static let fixtureRows: [MutualExclusionFixtureRow] = [
        MutualExclusionFixtureRow(
            rowNumber: 1, targetExperienceKey: "exp-a", negation: false,
            resolverReturns: false, expectedMatched: false, expectsWarning: false
        ),
        MutualExclusionFixtureRow(
            rowNumber: 2, targetExperienceKey: "exp-a", negation: true,
            resolverReturns: false, expectedMatched: true, expectsWarning: false
        ),
        MutualExclusionFixtureRow(
            rowNumber: 3, targetExperienceKey: "exp-a", negation: false,
            resolverReturns: true, expectedMatched: true, expectsWarning: false
        ),
        MutualExclusionFixtureRow(
            rowNumber: 4, targetExperienceKey: "exp-a", negation: true,
            resolverReturns: true, expectedMatched: false, expectsWarning: false
        ),
        MutualExclusionFixtureRow(
            rowNumber: 5, targetExperienceKey: "exp-a", negation: true,
            resolverReturns: false, expectedMatched: true, expectsWarning: false
        ),
        MutualExclusionFixtureRow(
            rowNumber: 6, targetExperienceKey: "exp-zz", negation: false,
            resolverReturns: nil, expectedMatched: false, expectsWarning: true
        ),
        MutualExclusionFixtureRow(
            rowNumber: 7, targetExperienceKey: "exp-zz", negation: true,
            resolverReturns: nil, expectedMatched: true, expectsWarning: true
        ),
        MutualExclusionFixtureRow(
            rowNumber: 8, targetExperienceKey: "exp-a", negation: true,
            resolverReturns: true, expectedMatched: false, expectsWarning: false
        )
    ]

    /// Sole `RuleCondition` construction site for a stateful (`bucketed_into_experience_key`) leaf.
    /// `key`/`matchType`/`value` are left at their fail-closed-safe defaults because the stateful
    /// branch must never reach `attributes[key]` -> `Comparisons` (AC7) — only `statefulTarget` and
    /// `negation` are consulted for this leaf shape.
    private func statefulCondition(targetExperienceKey: String, negation: Bool) -> RuleCondition {
        RuleCondition(
            key: "bucketed_into_experience_key",
            matchType: "",
            value: nil,
            negation: negation,
            statefulTarget: StatefulRuleTarget(
                ruleType: "bucketed_into_experience_key",
                targetExperienceKey: targetExperienceKey
            )
        )
    }

    // MARK: - AC1 + AC8 — the 8-row fixture, table-driven

    /// Drives all 8 rows through the REAL `RuleManager` with a FAKE three-state resolver, asserting
    /// BOTH the `matched` column (AC1) and the warn-only-on-unknown-target behavior (AC8) per row —
    /// `attributes` is always empty, proving AC4 structurally (the stateful leaf never has a `key` to
    /// look up).
    @Test("mutual-exclusion 8-row fixture: matched + warn-on-unknown-target", arguments: fixtureRows)
    func fixtureRow(_ row: MutualExclusionFixtureRow) {
        let logger = MockLogger()
        let manager = RuleManager(logger: logger)
        let group = RuleGroup(conditions: [
            statefulCondition(targetExperienceKey: row.targetExperienceKey, negation: row.negation)
        ])

        let matched = manager.evaluate(
            rules: [group],
            against: [:],
            resolvingBucketedIntoExperienceKey: { key in
                key == row.targetExperienceKey ? row.resolverReturns : nil
            }
        )
        #expect(
            matched == row.expectedMatched,
            "row \(row.rowNumber): expected matched == \(row.expectedMatched), got \(matched)"
        )

        let warnedNamingTarget = logger.entries().contains {
            $0.level == .warn && $0.message.contains(row.targetExperienceKey)
        }
        #expect(
            warnedNamingTarget == row.expectsWarning,
            "row \(row.rowNumber): expected warning-naming-'\(row.targetExperienceKey)' == \(row.expectsWarning)"
        )
    }

    /// AC8, isolated and stricter than the per-row check above: rows 1 and 5 (a KNOWN target the
    /// visitor is simply not bucketed into) must log NO warning AT ALL — not just no warning
    /// mentioning the key, but zero log lines of any kind from this evaluation.
    @Test(
        "AC8: known-target resolution (rows 1 & 5) logs no warning whatsoever",
        arguments: [fixtureRows[0], fixtureRows[4]]
    )
    func knownTargetLogsNoWarningAtAll(_ row: MutualExclusionFixtureRow) {
        let logger = MockLogger()
        let manager = RuleManager(logger: logger)
        let group = RuleGroup(conditions: [
            statefulCondition(targetExperienceKey: row.targetExperienceKey, negation: row.negation)
        ])

        _ = manager.evaluate(
            rules: [group],
            against: [:],
            resolvingBucketedIntoExperienceKey: { key in
                key == row.targetExperienceKey ? row.resolverReturns : nil
            }
        )
        #expect(
            logger.entries().isEmpty,
            "row \(row.rowNumber): a KNOWN target (resolver returned false, not nil) must log nothing"
        )
    }

    // MARK: - AC6-unit — intra-audience combination (stateful leaf + generic leaf)

    /// AND-block: a stateful leaf combined with a generic leaf passes ONLY when BOTH pass — exactly
    /// the existing `allSatisfy` AND semantics generic-only groups already ride (`RuleManagerTests
    /// .andGroupAllMustPass` / `.andGroupOneFailReturnsFalse`), now proven with ONE leaf of each kind
    /// in the SAME group.
    @Test("AC6-unit: AND-block combines a stateful leaf with a generic leaf like existing rules")
    func andBlockCombinesStatefulAndGenericLeaves() {
        let manager = RuleManager(logger: MockLogger())
        let group = RuleGroup(conditions: [
            statefulCondition(targetExperienceKey: "exp-a", negation: false),
            RuleCondition(key: "country", matchType: "equals", value: "US", negation: false)
        ])
        let bucketedIntoExpA: (String) -> Bool? = { $0 == "exp-a" ? true : nil }
        let notBucketedIntoExpA: (String) -> Bool? = { $0 == "exp-a" ? false : nil }

        #expect(
            manager.evaluate(
                rules: [group], against: ["country": "US"],
                resolvingBucketedIntoExperienceKey: bucketedIntoExpA
            ) == true,
            "both the stateful leaf (bucketed) and the generic leaf (country==US) pass -> AND true"
        )
        #expect(
            manager.evaluate(
                rules: [group], against: ["country": "UK"],
                resolvingBucketedIntoExperienceKey: bucketedIntoExpA
            ) == false,
            "stateful leaf passes but the generic leaf fails (country==UK) -> AND false"
        )
        #expect(
            manager.evaluate(
                rules: [group], against: ["country": "US"],
                resolvingBucketedIntoExperienceKey: notBucketedIntoExpA
            ) == false,
            "generic leaf passes but the stateful leaf fails (not bucketed into exp-a) -> AND false"
        )
    }

    /// OR-across-groups: a group containing ONLY a (failing) stateful leaf is compensated by a
    /// sibling group containing ONLY a (passing) generic leaf — exactly the existing `contains`
    /// OR semantics (`RuleManagerTests.orSecondGroupPasses`), now with a stateful group as one side.
    @Test("AC6-unit: OR-across-groups — a passing generic group compensates for a failing stateful group")
    func orAcrossGroupsGenericCompensatesForFailingStatefulGroup() {
        let manager = RuleManager(logger: MockLogger())
        let statefulGroup = RuleGroup(conditions: [
            statefulCondition(targetExperienceKey: "exp-a", negation: false)
        ])
        let genericGroup = RuleGroup(conditions: [
            RuleCondition(key: "country", matchType: "equals", value: "US", negation: false)
        ])
        let neverBucketed: (String) -> Bool? = { _ in false }

        #expect(
            manager.evaluate(
                rules: [statefulGroup, genericGroup],
                against: ["country": "US"],
                resolvingBucketedIntoExperienceKey: neverBucketed
            ) == true,
            "the generic group passing must carry the OR even though the stateful group fails"
        )
    }
}
