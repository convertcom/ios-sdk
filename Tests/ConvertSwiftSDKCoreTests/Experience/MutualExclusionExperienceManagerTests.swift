// Tests/ConvertSwiftSDKCoreTests/Experience/MutualExclusionExperienceManagerTests.swift
//
// RED-phase suite for M2 (iOS mutual-exclusion qs-04): the REAL, read-only resolver wired into
// `ExperienceManager`'s audience gate, exercised END-TO-END through the PUBLIC `selectVariation`
// API — no new Sources symbols are referenced here (the resolver / async-`audiencePasses` /
// `matching_options` composition change is entirely INTERNAL to `ExperienceManager`), so this
// file COMPILES today and FAILS AT RUNTIME. Spec of record:
//   _bmad-output/implementation-artifacts/2026-06-09-convert-ios-sdk/qs-04-mutual-exclusion-rule.md
// Task/plan: work/2026-07-15-ios-sdk-mutual-exclusion/workflow-state.yaml.
//
// ── Why this is RED today (two independent runtime gaps, not a compile error) ──────────────────
// (1) `ExperienceManager.audiencePasses` (Experience/ExperienceManager.swift:329-341) resolves each
// attached audience via `config.audience(id:)`, then reads its TYPED `rules?.value1`. For a
// DEGRADED audience (its rule tree embeds the unrecognised `bucketed_into_experience_key` leaf)
// that typed `rules` is `nil` by construction (`ProjectConfig+AudienceDecoding.swift`'s
// `reconstructAudience(fromSentinelPayload:)` never populates it) — so a degraded audience emits
// NO groups. With the sole attached audience emitting zero groups (the pure-exclusion AC2/AC3/AC5/
// AC8 scenarios), `ruleManager.evaluate(rules: [], against:)` fails CLOSED (`Rules/RuleManager
// .swift:53-61`) — an experience gated on a degraded mutual-exclusion audience returns `nil` for
// EVERY visitor, unconditionally, regardless of whether the visitor is actually bucketed into the
// target. Wrong for the never-ran-target case (AC2's second half) and produces no warning naming
// an unresolved target key (AC8).
// (2) `audiencePasses` CONCATENATES every attached audience's flattened groups into ONE flat outer
// OR (Experience/ExperienceManager.swift:326-328/363-369) and never reads
// `full.settings?.matching_options?.audiences` at all — so the qs-04 AC6 two-audience `ALL`/`ANY`
// scenarios (below) do not merely fail on the degraded audience (gap 1); even a fully-typed generic
// second audience would be OR-combined with the exclusion audience regardless of the experience's
// declared `matching_options.audiences`, which is a SEPARATE, additional divergence from JS parity
// (`javascript-sdk/packages/data/src/data-manager.ts:419-428`, `_isBucketingExclusionRule`/
// `_resolveBucketingExclusion`/`filterMatchedRecordsWithRule`, `data-manager.ts:1246-1345`).
//
// GREEN detects a degraded audience's stateful leaf via `RuleAdapter.flatten(_ sentinelRuleTree:
// JSONValue)` (reading the `"rules"` member off `ProjectConfig.degradedAudienceSentinels[id]`),
// resolves an EXCLUSION audience's match via a whole-audience-override seam (mirroring JS's
// `_resolveBucketingExclusion` — sibling leaves in the SAME audience tree are NEVER evaluated),
// resolves a GENERIC audience's match via the existing `RuleManager.evaluate` (unchanged, AC7),
// then composes the PER-AUDIENCE match booleans via `settings.matching_options.audiences`
// (`ALL` ⇒ every attached audience must match; `ANY`/absent ⇒ at least one must match — JS parity).
//
// ── Fixtures ─────────────────────────────────────────────────────────────────────────────────
// `MutualExclusionFixtures` (Support/MutualExclusionFixtures.swift) builds:
//   - `twoExperienceMutualExclusionConfig` — `exp-a` (always buckets, TARGET) + `exp-b` gated on
//     ONE degraded (pure-exclusion) audience — used by AC2/AC3/AC5/AC8.
//   - `twoAudienceMutualExclusionConfig` — `exp-a` (TARGET) + `exp-b` gated on TWO SEPARATE
//     audiences (a dedicated exclusion audience + a generic `country` audience), composed via
//     `settings.matching_options.audiences` — used by the AC6 tests below (the JS-parity
//     two-audience shape; the PRIOR mixed-single-audience shape, which combined a stateful and a
//     generic leaf inside ONE audience's tree via ordinary AND/OR, corresponded to no real JS code
//     path and has been REMOVED — see `MutualExclusionFixtures.swift`'s header).
//
// ── Test-hygiene ─────────────────────────────────────────────────────────────────────────────
// `attributes` is `[:]` (the default) everywhere except the two AC6 combination tests, which need
// a `country` value to drive the generic audience's leaf — proving AC4 structurally for every
// pure-exclusion scenario. EventBus delivery is asynchronous (`fire` dispatches each callback as
// an independent `MainActor` `Task`), so every fire-count read goes through `drain()` (a
// `MainActor.run {}` executor barrier) — mirrors `ExperienceManagerTests.drain()` verbatim.
// Every scenario shares ONE subject factory / one select helper (SonarQube 3% convention already
// established by the sibling `ExperienceManagerTests`), so no ≥10-line block is copy-pasted.

import Foundation
import Testing
@testable import ConvertSwiftSDKCore

@Suite("ExperienceManager mutual-exclusion end-to-end (bucketed_into_experience_key) — IOS-3 RED")
struct MutualExclusionExperienceManagerTests {

    // MARK: - Shared identifiers

    private enum Ids {
        static let account = "a"
        static let project = "p"
        static let visitorRanExpA = "v-ran-a"
        static let visitorFresh = "v-fresh"

        /// The storeKey the pipeline derives — `<account>-<project>-<visitor>`.
        static func storeKey(_ visitor: String) -> String { "\(account)-\(project)-\(visitor)" }
    }

    // MARK: - Subject factory (SonarQube 3% new-duplicated-lines gate)

    /// Builds the subject with REAL collaborators wired to the passed (or default) doubles —
    /// mirrors `ExperienceManagerTests.makeExperienceManager` (a sibling suite, not reachable
    /// from this file's `private` scope, so re-declared here rather than forked in shape).
    private func makeExperienceManager(
        decisionStore: DecisionStore = DecisionStore(logger: MockLogger(), fileStore: MockFileStore()),
        eventSink: MockEventSink = MockEventSink(),
        eventBus: EventBus = EventBus(),
        logger: MockLogger = MockLogger()
    ) -> ExperienceManager {
        ExperienceManager(
            ruleManager: RuleManager(logger: logger),
            bucketingManager: BucketingManager(eventSink: eventSink, logger: logger),
            decisionStore: decisionStore,
            eventBus: eventBus,
            logger: logger
        )
    }

    /// Invokes `selectVariation` with the shared account/project ids and per-scenario visitor /
    /// attributes, with tracking always on (the mutual-exclusion rule is orthogonal to
    /// `enableTracking`, already covered by `ExperienceManagerTests`).
    private func select(
        _ subject: ExperienceManager,
        key: String,
        in config: ProjectConfig,
        visitorId: String,
        attributes: [String: String] = [:]
    ) async -> Variation? {
        await subject.selectVariation(
            forKey: key,
            in: config,
            visitorId: visitorId,
            accountId: Ids.account,
            projectId: Ids.project,
            attributes: attributes,
            locationProperties: [:],
            enableTracking: true
        )
    }

    /// Lets already-dispatched `MainActor` callbacks run before assertions read a capture.
    /// Mirrors `ExperienceManagerTests.drain()` verbatim (see that file's doc for why
    /// `Task.yield()` does not suffice).
    private func drain() async {
        await MainActor.run { }
    }

    // MARK: - AC2 + AC4 — end-to-end exclusion, empty attributes throughout

    /// A visitor already bucketed into `exp-a` is excluded from `exp-b` (`negated: true` against
    /// `exp-a`) — the core mutual-exclusion behavior, with `attributes` empty throughout (AC4).
    @Test("AC2/AC4: a visitor already bucketed into exp-a is excluded from exp-b (negated rule)")
    func visitorBucketedIntoExpAIsExcludedFromExpB() async throws {
        let config = try MutualExclusionFixtures.twoExperienceMutualExclusionConfig(
            audienceRulesJSON: MutualExclusionFixtures.singleLeafRulesJSON(
                MutualExclusionFixtures.statefulLeafJSON(targetExperienceKey: "exp-a", negated: true)
            )
        )
        let subject = makeExperienceManager()

        let variationA = await select(subject, key: "exp-a", in: config, visitorId: Ids.visitorRanExpA)
        #expect(variationA != nil, "exp-a has no gates and must bucket")

        let variationB = await select(subject, key: "exp-b", in: config, visitorId: Ids.visitorRanExpA)
        #expect(variationB == nil, "a visitor already bucketed into exp-a must be excluded from exp-b")
    }

    /// A DIFFERENT, fresh visitor who never ran `exp-a` buckets into `exp-b` normally — the
    /// negated exclusion dissolves when the visitor was never bucketed into the target.
    @Test("AC2/AC4: a fresh visitor who never ran exp-a buckets into exp-b normally")
    func freshVisitorNeverRanExpABucketsIntoExpB() async throws {
        let config = try MutualExclusionFixtures.twoExperienceMutualExclusionConfig(
            audienceRulesJSON: MutualExclusionFixtures.singleLeafRulesJSON(
                MutualExclusionFixtures.statefulLeafJSON(targetExperienceKey: "exp-a", negated: true)
            )
        )
        let subject = makeExperienceManager()

        let variationB = await select(subject, key: "exp-b", in: config, visitorId: Ids.visitorFresh)

        #expect(
            variationB?.experienceKey == "exp-b",
            "a visitor who never ran exp-a must bucket into exp-b normally (negated exclusion dissolves)"
        )
    }

    // MARK: - AC3 — cross-relaunch persistence (row 8)

    /// `exp-a`'s decision, persisted by ONE `DecisionStore` instance, still excludes `exp-b` after
    /// a FRESH `DecisionStore` + fresh `ExperienceManager` are constructed against the SAME
    /// `MockFileStore` container and rehydrated via `loadFromDisk()` — simulating an app relaunch.
    @Test("AC3: exp-a's decision persisted by one DecisionStore excludes exp-b after a fresh relaunch")
    func crossRelaunchPersistenceExcludesExpB() async throws {
        let config = try MutualExclusionFixtures.twoExperienceMutualExclusionConfig(
            audienceRulesJSON: MutualExclusionFixtures.singleLeafRulesJSON(
                MutualExclusionFixtures.statefulLeafJSON(targetExperienceKey: "exp-a", negated: true)
            )
        )
        let sharedFiles = MockFileStore()
        let firstLaunchStore = DecisionStore(logger: MockLogger(), fileStore: sharedFiles)
        let firstLaunchSubject = makeExperienceManager(decisionStore: firstLaunchStore)
        let variationA = await select(
            firstLaunchSubject, key: "exp-a", in: config, visitorId: Ids.visitorRanExpA
        )
        #expect(variationA != nil, "exp-a has no gates and must bucket on the first launch")

        // Simulate relaunch: a FRESH DecisionStore + fresh ExperienceManager against the SAME
        // MockFileStore container, rehydrated from disk — NOT carried over in-memory.
        let relaunchStore = DecisionStore(logger: MockLogger(), fileStore: sharedFiles)
        await relaunchStore.loadFromDisk()
        let relaunchSubject = makeExperienceManager(decisionStore: relaunchStore)

        let variationB = await select(
            relaunchSubject, key: "exp-b", in: config, visitorId: Ids.visitorRanExpA
        )

        #expect(
            variationB == nil,
            "row 8: a decision persisted before relaunch must still exclude exp-b after rehydration"
        )
    }

    // MARK: - AC5 — read-only: no new bucketing / storage write / tracking event from the check

    /// Evaluating `exp-b`'s exclusion audience must not itself bucket the target, write a new
    /// sticky decision, or enqueue a tracking event — the ONLY store entry / enqueue / fire must
    /// be the ones `exp-a`'s OWN run already produced.
    @Test("AC5: evaluating exp-b's exclusion rule triggers no new bucketing, write, or tracking event")
    func exclusionRuleEvaluationIsReadOnly() async throws {
        let config = try MutualExclusionFixtures.twoExperienceMutualExclusionConfig(
            audienceRulesJSON: MutualExclusionFixtures.singleLeafRulesJSON(
                MutualExclusionFixtures.statefulLeafJSON(targetExperienceKey: "exp-a", negated: true)
            )
        )
        let store = DecisionStore(logger: MockLogger(), fileStore: MockFileStore())
        let sink = MockEventSink()
        let bus = EventBus()
        let subject = makeExperienceManager(decisionStore: store, eventSink: sink, eventBus: bus)
        let fireCount = LockedBox(0)
        _ = await bus.on(.bucketing) { _ in fireCount.withLock { $0 += 1 } }

        _ = await select(subject, key: "exp-a", in: config, visitorId: Ids.visitorRanExpA)
        await drain()
        let eventsAfterA = await sink.recordedEvents().count
        let firesAfterA = fireCount.get

        let variationB = await select(subject, key: "exp-b", in: config, visitorId: Ids.visitorRanExpA)
        await drain()

        #expect(
            variationB == nil,
            "the exclusion must still hold for this read-only assertion to be meaningful"
        )
        let eventsAfterB = await sink.recordedEvents().count
        #expect(eventsAfterB == eventsAfterA, "evaluating exp-b's audience must enqueue no new tracking event")
        #expect(fireCount.get == firesAfterA, "evaluating exp-b's audience must fire no new .bucketing event")
        let bucketing = await store.bucketingDecisions(forStoreKey: Ids.storeKey(Ids.visitorRanExpA))
        #expect(
            bucketing.count == 1,
            "only exp-a's decision may be stored; exp-b must not be bucketed into or written"
        )
    }

    // MARK: - AC6 — cross-AUDIENCE combination via `matching_options.audiences` (ALL / ANY)
    //
    // JS-parity two-audience shape (`MutualExclusionFixtures.twoAudienceMutualExclusionConfig`):
    // `exp-b` carries TWO SEPARATE attached audiences — a dedicated exclusion audience (the negated
    // `bucketed_into_experience_key` leaf ALONE, targeting `exp-a`) and a generic `country == "US"`
    // audience — composed via `exp-b`'s `settings.matching_options.audiences`. `audiencePasses`
    // never reads `matching_options` at all today (it OR-concatenates every attached audience's
    // groups unconditionally), so the ALL scenario below is the one that discriminates RED from
    // GREEN: today a visitor excluded by the exclusion audience alone still passes because the
    // generic audience's OR carries it through, regardless of the declared `ALL` requirement.

    /// ALL: both the dedicated exclusion audience AND the generic `country` audience must match —
    /// a visitor bucketed into `exp-a` fails the (negated) exclusion audience, so `exp-b` must be
    /// excluded even though the generic `country == "US"` audience independently matches (today's
    /// flat-OR gate incorrectly lets this visitor through via the passing generic audience alone).
    @Test("AC6: ALL — both the exclusion audience and the generic country audience must match")
    func allMatchingOptionRequiresBothAudiencesToPass() async throws {
        let config = try MutualExclusionFixtures.twoAudienceMutualExclusionConfig(matchingOptions: "all")
        let subject = makeExperienceManager()

        let excludedDespiteGenericMatch = await select(
            subject, key: "exp-b", in: config, visitorId: Ids.visitorRanExpA, attributes: ["country": "US"]
        )
        #expect(
            excludedDespiteGenericMatch == nil,
            "ALL: bucketed into exp-a fails the exclusion audience even though country==US passes -> excluded"
        )

        let passesWhenBothMatch = await select(
            subject, key: "exp-b", in: config, visitorId: "v-all-fresh-us", attributes: ["country": "US"]
        )
        #expect(
            passesWhenBothMatch != nil,
            "ALL: never ran exp-a (exclusion audience passes) AND country==US (generic passes) -> exp-b serves"
        )
    }

    /// ANY: either audience matching suffices — a visitor bucketed into `exp-a` fails the
    /// exclusion audience, but the generic `country == "US"` audience compensates, so `exp-b`
    /// still serves; a visitor matching NEITHER audience is excluded.
    @Test("AC6: ANY — either the exclusion audience or the generic country audience matching suffices")
    func anyMatchingOptionEitherAudiencePassing() async throws {
        let config = try MutualExclusionFixtures.twoAudienceMutualExclusionConfig(matchingOptions: "any")
        let subject = makeExperienceManager()

        let variationA = await select(subject, key: "exp-a", in: config, visitorId: Ids.visitorRanExpA)
        #expect(variationA != nil, "exp-a has no gates and must bucket")

        let passesViaGenericAudience = await select(
            subject, key: "exp-b", in: config, visitorId: Ids.visitorRanExpA, attributes: ["country": "US"]
        )
        #expect(
            passesViaGenericAudience != nil,
            "ANY: the exclusion audience fails (bucketed into exp-a) but country==US passes -> exp-b serves"
        )

        // A SEPARATE visitor for the neither-matches assertion (not `Ids.visitorRanExpA` again): that
        // visitor already holds a STICKY exp-b decision from the `passesViaGenericAudience` call above,
        // and a sticky hit short-circuits every gate (by design) regardless of `matching_options` — reusing
        // it here would test sticky-return semantics, not the ALL/ANY composition. This visitor is bucketed
        // into exp-a fresh (so the exclusion audience fails the same way) but has NO prior exp-b decision.
        let visitorNeitherMatches = "v-any-neither"
        let priorExpA = await select(subject, key: "exp-a", in: config, visitorId: visitorNeitherMatches)
        #expect(priorExpA != nil, "exp-a has no gates and must bucket for the neither-matches visitor too")
        let excludedWhenNeitherMatches = await select(
            subject, key: "exp-b", in: config, visitorId: visitorNeitherMatches, attributes: ["country": "UK"]
        )
        #expect(
            excludedWhenNeitherMatches == nil,
            "ANY: the exclusion audience fails AND country==UK fails the generic audience -> exp-b excluded"
        )
    }

    // MARK: - AC8 — unknown target experience key logs a warning naming that key

    /// A rule targeting an experience key absent from the config resolves `bucketedRaw = false`
    /// (unknown target) and logs a warning NAMING the unresolved key — not the generic
    /// "empty rule set" message the current (broken) wiring emits.
    @Test("AC8: targeting an unknown experience key logs a warning naming it")
    func unknownTargetExperienceKeyLogsWarning() async throws {
        let config = try MutualExclusionFixtures.twoExperienceMutualExclusionConfig(
            audienceRulesJSON: MutualExclusionFixtures.singleLeafRulesJSON(
                MutualExclusionFixtures.statefulLeafJSON(targetExperienceKey: "exp-zz", negated: false)
            )
        )
        let logger = MockLogger()
        let subject = makeExperienceManager(logger: logger)

        let variation = await select(subject, key: "exp-b", in: config, visitorId: Ids.visitorFresh)

        #expect(variation == nil, "an unrecognised target resolves bucketedRaw=false -> matched=false")
        #expect(
            logger.entries().contains { $0.level == .warn && $0.message.contains("exp-zz") },
            "the unknown target key must be named in a warning"
        )
    }
}
