// Tests/ConvertSwiftSDKCoreTests/Rules/MutualExclusionRuleManagerTests.swift
//
// RED-phase suite for M2 (iOS mutual-exclusion qs-04): the WHOLE-AUDIENCE-OVERRIDE resolution seam
// that resolves a `bucketed_into_experience_key` rule leaf. Spec of record:
//   _bmad-output/implementation-artifacts/2026-06-09-convert-ios-sdk/qs-04-mutual-exclusion-rule.md
// Task/plan: work/2026-07-15-ios-sdk-mutual-exclusion/workflow-state.yaml.
//
// ── RE-ARCHITECTURE: the resolver seam moves OUT of `RuleManager` ──────────────────────────────
// The PRIOR design (this suite, pre-rework) threaded a `resolvingBucketedIntoExperienceKey`
// resolver INTO `RuleManager.evaluate(rules:against:resolvingBucketedIntoExperienceKey:)`, letting a
// stateful leaf be mixed with generic leaves inside the SAME `RuleGroup` (AND) or across sibling
// groups (OR) and resolved by the SAME generic rule engine. That does NOT correspond to any real JS
// code path: the JS reference (`javascript-sdk/packages/data/src/data-manager.ts`,
// `feat/mutual-exclusion-rule`) resolves mutual exclusion at the WHOLE-AUDIENCE level —
// `_isBucketingExclusionRule` (:1246-1265) walks ONE audience's OR→AND→OR_WHEN tree for ANY
// `bucketed_into_experience_key` leaf; if found, `filterMatchedRecordsWithRule` (:1336-1345) resolves
// the ENTIRE audience's match via `_resolveBucketingExclusion` (:1282-1304) ALONE — sibling leaves in
// the SAME audience tree are NEVER evaluated, and the generic rule engine (`RuleManager`-equivalent,
// `isRuleMatched`) is never even called for that audience. This rework moves the resolution to a
// dedicated, `RuleManager`-independent seam so iOS mirrors that whole-audience-override shape; see
// `MutualExclusionFixtures.swift`'s header for the two-audience (`matching_options`) composition this
// enables at the `ExperienceManager` layer (`MutualExclusionExperienceManagerTests.swift`, AC6).
//
// Consequently:
//   - `RuleManager.evaluate` DROPS its `resolvingBucketedIntoExperienceKey` parameter entirely — the
//     generic engine never resolves a stateful leaf again (it is bypassed at the audience level,
//     never handed a stateful-leaf-carrying `RuleGroup`).
//   - The 8-row fixture (AC1) and the "known target logs no warning" check (AC8) are RE-POINTED to
//     the NEW resolution seam below instead of `RuleManager.evaluate(...
//     resolvingBucketedIntoExperienceKey:)` — all 8 rows and their expected `matched`/warn outcomes
//     are FROZEN VERBATIM (unchanged from the qs-04 fixture table).
//   - The two prior "AC6-unit" tests (`andBlockCombinesStatefulAndGenericLeaves` /
//     `orAcrossGroupsGenericCompensatesForFailingStatefulGroup`), which exercised a stateful leaf
//     mixed with a generic leaf inside ONE `RuleGroup` fed to `RuleManager.evaluate`, are REMOVED —
//     that composition no longer represents any reachable code path once resolution moves to the
//     whole-audience level (an exclusion audience's sibling leaves, if any, are never evaluated by
//     ANY engine). Real ALL/ANY combination is now covered at the `ExperienceManager` two-audience
//     layer (`MutualExclusionExperienceManagerTests.swift`, AC6), not by mixing leaves in one
//     `RuleGroup`.
//   - `RuleCondition.statefulTarget` / `StatefulRuleTarget` are UNCHANGED and still populated by
//     `RuleAdapter.flatten(_ sentinelRuleTree: JSONValue)` (see the sibling
//     `MutualExclusionJSONFlattenTests.swift` / `MutualExclusionGenericRegressionTests.swift`, both
//     unaffected by this rework) — they remain the DETECTION representation a whole-audience caller
//     walks to find the exclusion leaf; only the RESOLUTION step (this file) moves out of
//     `RuleManager`.
//
// ── ASSUMED SHAPE (spec-silent — a M2 implementation choice, recorded here and in the sibling
// decision log for the decision_audit checkpoint; mirrors JS's `_resolveBucketingExclusion`
// (`data-manager.ts:1282-1304`) almost verbatim) ──────────────────────────────────────────────────
//
//   internal enum BucketingExclusion {
//       /// Mirrors JS `_resolveBucketingExclusion`: `bucketedRaw = resolver(targetExperienceKey)`
//       /// (`nil` == unknown target -> WARN naming the key, default `bucketedRaw = false`; a
//       /// resolver-returned `false` == a KNOWN target the visitor is simply not bucketed into ->
//       /// NO warn); `matched = negated ? !bucketedRaw : bucketedRaw`, applied exactly once.
//       static func resolve(
//           targetExperienceKey: String,
//           negated: Bool,
//           resolver: (String) -> Bool?,
//           logger: Logger
//       ) -> Bool
//   }
//
// This is a NEW type/file (`Sources/ConvertSwiftSDKCore/Rules/BucketingExclusion.swift`, assumed —
// not yet created), so this file MUST FAIL TO COMPILE today ("cannot find 'BucketingExclusion' in
// scope") — the expected, correct RED state; as with the IOS-1/IOS-2 precedent this breaks
// `swift build`/`swift test` for the WHOLE `ConvertSwiftSDKCoreTests` target (single SPM module)
// until GREEN lands the symbol.
//
// Fixture: qs-04's inline 8-row table (spec lines 70-79), FROZEN VERBATIM from the pre-rework suite —
// only the call site (which seam resolves each row) changed, never the rows or expected outcomes.
// Config context: `exp-a` (id `100111`), `exp-b` (id `100222`) both exist; `exp-zz` does NOT (rows
// 6/7 — the resolver returns `nil` for it). At THIS (unit) level there is no real
// `DecisionStore`/`ExperienceManager` — the "stored bucketing map" column is simulated purely by the
// FAKE resolver's return value per row (a real config/storage resolver is the `ExperienceManager`
// integration layer's job, `MutualExclusionExperienceManagerTests.swift`). Visitor `attributes` are
// irrelevant here — proving AC4 ("zero new application inputs") structurally: the new seam has no
// `attributes` parameter at all, so it cannot consult them even in principle.
//
// SonarQube `new_duplicated_lines_density` guard: ONE parameterized `@Test(arguments:)` drives all
// 8 rows from a single `fixtureRows` table + one shared `MutualExclusionFixtureRow` model — no
// per-row test-function duplication.

import Testing
@testable import ConvertSwiftSDKCore

@Suite("Bucketing-exclusion whole-audience resolution (bucketed_into_experience_key) — RED")
struct MutualExclusionRuleManagerTests {

    // MARK: - Fixture row model (shared — SonarQube duplication guard)

    /// One row of the qs-04 inline 8-row fixture (spec lines 70-79), collapsed to the fields the
    /// UNIT-level resolver seam actually needs: the target key, the rule's `negated` flag, what the
    /// FAKE resolver returns for that key (`nil` == "unknown target"), and the expected outcomes.
    struct MutualExclusionFixtureRow: Sendable {
        /// The qs-04 spec's row number (1-8), carried through purely for readable failure messages.
        let rowNumber: Int
        /// `rule.value` — the target experience KEY the leaf names.
        let targetExperienceKey: String
        /// The leaf's `matching.negated` flag.
        let negation: Bool
        /// What the fake three-state resolver returns when queried for `targetExperienceKey`:
        /// `true` (bucketed), `false` (known target, not bucketed), or `nil` (unknown target).
        let resolverReturns: Bool?
        /// The qs-04 fixture's expected `matched` column.
        let expectedMatched: Bool
        /// Whether a `.warn` line naming `targetExperienceKey` must be logged (only rows 6/7 —
        /// `resolverReturns == nil`, an unknown target; AC8).
        let expectsWarning: Bool
    }

    /// The qs-04 8-row fixture (spec lines 70-79), FROZEN VERBATIM from the pre-rework suite — rows
    /// and expected `matched`/warn outcomes are unchanged; only the resolution seam under test moved
    /// (see this file's header). Row 8 is DELIBERATELY identical in resolver-stance/expectation to
    /// row 4 at THIS unit level — the spec's row-8 scenario ("present only in persisted storage,
    /// fresh SDK instance, warm files") is a cross-relaunch integration concern this seam cannot
    /// distinguish from row 4 without a real `DecisionStore`; that distinction is the
    /// `ExperienceManager` integration layer's job (out of scope here).
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

    /// Builds the fake three-state resolver for `row` — returns `row.resolverReturns` when queried
    /// for `row.targetExperienceKey`, `nil` for any other key (defensive; never exercised here since
    /// every row queries exactly one key). Centralized so no test body re-inlines the closure
    /// (SonarQube 3% guard).
    private func fakeResolver(for row: MutualExclusionFixtureRow) -> (String) -> Bool? {
        { key in key == row.targetExperienceKey ? row.resolverReturns : nil }
    }

    // MARK: - AC1 + AC8 — the 8-row fixture, table-driven, against the NEW whole-audience seam

    /// Drives all 8 rows through the NEW `BucketingExclusion.resolve` seam with a FAKE three-state
    /// resolver, asserting BOTH the `matched` column (AC1) and the warn-only-on-unknown-target
    /// behavior (AC8) per row — the seam has no `attributes` parameter at all, proving AC4
    /// structurally (there is nothing for the stateful leaf to look up even in principle).
    @Test("mutual-exclusion 8-row fixture: matched + warn-on-unknown-target", arguments: fixtureRows)
    func fixtureRow(_ row: MutualExclusionFixtureRow) {
        let logger = MockLogger()

        let matched = BucketingExclusion.resolve(
            targetExperienceKey: row.targetExperienceKey,
            negated: row.negation,
            resolver: fakeResolver(for: row),
            logger: logger
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

        _ = BucketingExclusion.resolve(
            targetExperienceKey: row.targetExperienceKey,
            negated: row.negation,
            resolver: fakeResolver(for: row),
            logger: logger
        )
        #expect(
            logger.entries().isEmpty,
            "row \(row.rowNumber): a KNOWN target (resolver returned false, not nil) must log nothing"
        )
    }
}
