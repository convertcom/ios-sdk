// Tests/ConvertSwiftSDKCoreTests/Rules/RuleManagerTests.swift
// AND/OR rule-evaluation suite for `RuleManager.evaluate(rules:against:)` (Epic 3 / Story 3 —
// audience / location rule evaluation).
//
// RED phase (TDD): `RuleManager`, `RuleGroup`, and `RuleCondition` do NOT exist yet
// (Sources/ConvertSwiftSDKCore/Rules/ is unwritten for these symbols). This file MUST fail to
// compile against those missing symbols — that is the expected, correct RED state. The
// expectations below define the contract the to-be-built implementation has to satisfy.
//
// GROUND TRUTH: the boolean semantics encode the LIVE JavaScript SDK behavior verified
// directly against `javascript-sdk/packages/rules/src/rule-manager.ts`:
//   - The outer `[RuleGroup]` is an OR — `evaluate` passes if ANY group passes; an empty
//     outer array `[]` → false + a WARN log line.
//   - A `RuleGroup` (one AND block) passes only if ALL of its conditions pass (short-circuit
//     on the first false); an empty `conditions == []` → false + a WARN log line.
//   - Each condition looks up `attributes[condition.key]` (nil when absent) and dispatches
//     that (possibly nil) value to the comparator — exists/doesNotExist semantics rely on nil
//     reaching it, so `RuleManager` never short-circuits before dispatch.
//
// Case-folding note: `equals` is case-insensitive (it lowercases both sides). All vectors
// here use exact-case, unambiguous values ("US" == "US", "30" == "30") so these tests stay
// decoupled from the case-folding contract — that contract is ComparisonsTests' job.

import Testing
@testable import ConvertSwiftSDKCore

@Suite("RuleManager")
struct RuleManagerTests {

    // MARK: - Construction factory (single construction site — SonarQube duplication guard)

    /// Sole `RuleManager` construction site. Every test routes through this so the
    /// initializer is written exactly once (keeps `new_duplicated_lines_density` ≤ 3%).
    /// The `logger:` overload lets tests that must inspect emitted WARN lines own a named
    /// `MockLogger` while construction still happens here.
    private func makeRuleManager(logger: MockLogger) -> RuleManager {
        RuleManager(logger: logger)
    }

    /// Convenience for tests that do not inspect the log — supplies a throwaway `MockLogger`.
    private func makeRuleManager() -> RuleManager {
        makeRuleManager(logger: MockLogger())
    }

    // MARK: - AND-block semantics (AC3)

    /// AND block of two matching conditions → true (both `country == US` and `age == 30` hold).
    @Test("AND group: all conditions must pass")
    func andGroupAllMustPass() {
        let manager = makeRuleManager()
        let group = RuleGroup(conditions: [
            RuleCondition(key: "country", matchType: "equals", value: "US", negation: false),
            RuleCondition(key: "age", matchType: "equals", value: "30", negation: false)
        ])
        let attrs = ["country": "US", "age": "30"]
        #expect(manager.evaluate(rules: [group], against: attrs) == true)
    }

    /// AND block where the second condition fails (`age == 99` vs attr `30`) → false.
    @Test("AND group: one failing condition returns false")
    func andGroupOneFailReturnsFalse() {
        let manager = makeRuleManager()
        let group = RuleGroup(conditions: [
            RuleCondition(key: "country", matchType: "equals", value: "US", negation: false),
            RuleCondition(key: "age", matchType: "equals", value: "99", negation: false)
        ])
        let attrs = ["country": "US", "age": "30"]
        #expect(manager.evaluate(rules: [group], against: attrs) == false)
    }

    // MARK: - OR-of-groups semantics (AC5)

    /// OR of two groups where only the second matches (`country == US`) → true.
    @Test("OR: second group passes → true")
    func orSecondGroupPasses() {
        let manager = makeRuleManager()
        let group1 = RuleGroup(conditions: [
            RuleCondition(key: "country", matchType: "equals", value: "UK", negation: false)
        ])
        let group2 = RuleGroup(conditions: [
            RuleCondition(key: "country", matchType: "equals", value: "US", negation: false)
        ])
        let attrs = ["country": "US"]
        #expect(manager.evaluate(rules: [group1, group2], against: attrs) == true)
    }

    // MARK: - Empty-collection guards (AC3 — false AND a WARN line)

    /// Empty outer OR (`rules == []`) → false, and a `.warn` line is logged.
    /// Uses a named `MockLogger` (routed through the factory) so the emitted log is inspectable.
    @Test("empty outer OR returns false and logs a warning")
    func emptyOuterOrReturnsFalse() {
        let logger = MockLogger()
        let manager = makeRuleManager(logger: logger)
        let result = manager.evaluate(rules: [], against: [:])
        #expect(result == false)
        #expect(logger.entries().contains { $0.level == .warn })
    }

    /// Empty inner AND group (`conditions == []`) → false, and a `.warn` line is logged.
    /// Uses a named `MockLogger` (routed through the factory) so the emitted log is inspectable.
    @Test("empty inner AND group returns false and logs a warning")
    func emptyAndGroupReturnsFalse() {
        let logger = MockLogger()
        let manager = makeRuleManager(logger: logger)
        let group = RuleGroup(conditions: [])
        let result = manager.evaluate(rules: [group], against: [:])
        #expect(result == false)
        #expect(logger.entries().contains { $0.level == .warn })
    }

    // MARK: - Absent-key dispatch (AC2 — nil must reach the comparator)

    /// AC2 regression guard at the RuleManager level: an absent attribute key resolves to nil and
    /// that nil must flow through to `Comparisons` so `doesNotExist` returns true. Guards against a
    /// future `guard let` short-circuit that would skip dispatch for missing keys.
    @Test("absent key with doesNotExist returns true (nil flows to comparator)")
    func absentKeyDoesNotExistReturnsTrue() {
        let manager = makeRuleManager()
        let group = RuleGroup(conditions: [
            RuleCondition(key: "missingAttr", matchType: "doesNotExist", value: nil, negation: false)
        ])
        #expect(manager.evaluate(rules: [group], against: ["country": "US"]) == true)
    }

    /// AC2 regression guard at the RuleManager level: an absent attribute key resolves to nil and
    /// that nil must flow through to `Comparisons` so `exists` returns false. Guards against a
    /// future `guard let` short-circuit that would skip dispatch for missing keys.
    @Test("absent key with exists returns false (nil flows to comparator)")
    func absentKeyExistsReturnsFalse() {
        let manager = makeRuleManager()
        let group = RuleGroup(conditions: [
            RuleCondition(key: "missingAttr", matchType: "exists", value: nil, negation: false)
        ])
        #expect(manager.evaluate(rules: [group], against: ["country": "US"]) == false)
    }

    // MARK: - Audience × Location composition (AC6)

    /// `RuleManager` is attribute-set-agnostic: the same evaluator runs the audience group
    /// against visitor attributes and the location group against location props. Eligibility is
    /// the AND of both calls — exactly how `ExperienceManager` will compose them in Story 3.4.
    @Test("audience rules vs location rules: both must pass")
    func audienceAndLocationBothMustPass() {
        let manager = makeRuleManager()
        // Audience: country == "US"
        let audienceGroup = RuleGroup(conditions: [
            RuleCondition(key: "country", matchType: "equals", value: "US", negation: false)
        ])
        // Location: city == "New York"
        let locationGroup = RuleGroup(conditions: [
            RuleCondition(key: "city", matchType: "equals", value: "New York", negation: false)
        ])

        // Both pass → eligible.
        let audiencePass = manager.evaluate(rules: [audienceGroup], against: ["country": "US"])
        let locationPass = manager.evaluate(rules: [locationGroup], against: ["city": "New York"])
        #expect(audiencePass && locationPass)

        // Visitor fails audience → not eligible.
        let audienceFail = manager.evaluate(rules: [audienceGroup], against: ["country": "UK"])
        #expect(!audienceFail)

        // Visitor passes audience but location fails → not eligible.
        let locationFail = manager.evaluate(rules: [locationGroup], against: ["city": "Los Angeles"])
        #expect(!locationFail)
    }
}
