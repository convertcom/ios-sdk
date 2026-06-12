// Tests/ConvertSDKCoreTests/Data/DecisionStoreTests.swift
// RED-phase contract for the `DecisionStore` sticky-variation store (Epic 3 / Story 4).
//
// The `DecisionStore` actor is currently a no-arg stub — none of the members exercised below
// (the `init(logger:fileStore:maxEntries:)` injection, `loadFromDisk()`, `stickyVariationId`,
// `saveDecision`) nor `Defaults.localStoreLimit` exist yet, so this suite is EXPECTED to fail
// to COMPILE (RED). The GREEN-phase implementer MUST satisfy every contract asserted here.

import Foundation
import Testing
@testable import ConvertSDKCore

/// RED-phase contract for the visitor-keyed sticky-variation store.
///
/// CONTRACT under test (the GREEN-phase implementer MUST satisfy these):
/// - `init(logger:fileStore:maxEntries:)` injects the log sink, the file-I/O port, and the
///   LRU capacity (defaulting to `Defaults.localStoreLimit`).
/// - `saveDecision(variationId:experienceId:storeKey:)` merges `variationId` into that
///   `storeKey`'s `StoreData.bucketing[experienceId]`, updates LRU recency, and persists the
///   whole `[String: StoreData]` dict to disk via `fileStore.write`. When at capacity and the
///   `storeKey` is NEW, it evicts the least-recently-accessed entry BEFORE inserting.
/// - `stickyVariationId(forExperience:storeKey:)` returns the stored variation ID (or `nil`),
///   and on a HIT bumps that `storeKey` to the most-recently-used end of the LRU order — so a
///   read, not just a write, refreshes recency.
/// - `loadFromDisk()` reads via `fileStore`, decodes `[String: StoreData]`, and hydrates the
///   store; on a decode failure (corrupt / truncated bytes) it logs a `warn`-level line and
///   leaves the store EMPTY — it never throws or crashes.
///
/// The `storeKey` is the full `accountId-projectId-visitorId` string; tests pass it pre-built.
@Suite("DecisionStore")
struct DecisionStoreTests {
    // MARK: Shared fixtures & helpers (SonarQube 3% new-duplicated-lines gate)

    /// Fresh store per scenario — one factory instead of re-wiring the injection per test, so no
    /// test inline-constructs the actor (SonarQube CPD operates on tokens, not names). `maxEntries`
    /// defaults to the production limit; the LRU-eviction tests pass a small cap.
    private func makeDecisionStore(
        logger: MockLogger = MockLogger(),
        fileStore: MockFileStore = MockFileStore(),
        maxEntries: Int = Defaults.localStoreLimit
    ) -> DecisionStore {
        DecisionStore(logger: logger, fileStore: fileStore, maxEntries: maxEntries)
    }

    /// Builds a `StoreData` carrying only `bucketing` (the field this story exercises); the other
    /// three required fields are empty. The single source of `StoreData` construction so no test
    /// re-inlines the four-argument init (SonarQube CPD). `Segments()` is the all-`nil` empty value.
    private func makeStoreData(bucketing: [String: String]) -> StoreData {
        StoreData(bucketing: bucketing, goalTriggered: [:], segments: Segments(), locations: [:])
    }

    // MARK: Save / retrieve

    @Test("a saved decision is retrievable by experience + storeKey")
    func saveAndRetrieve() async {
        let store = makeDecisionStore()

        await store.saveDecision(variationId: "var-a", experienceId: "exp-1", storeKey: "acc-proj-v1")
        let sticky = await store.stickyVariationId(forExperience: "exp-1", storeKey: "acc-proj-v1")

        #expect(sticky == "var-a")
    }

    @Test("an unsaved experience / storeKey resolves to nil")
    func returnsNilForUnknownExperience() async {
        let store = makeDecisionStore()

        let sticky = await store.stickyVariationId(forExperience: "exp-unknown", storeKey: "acc-proj-none")

        #expect(sticky == nil)
    }

    // MARK: bucketingDecisions(forStoreKey:)

    /// RED-phase contract for the NEW `bucketingDecisions(forStoreKey:)` accessor (does NOT exist
    /// yet): `public func bucketingDecisions(forStoreKey storeKey: String) -> [String: String]`.
    /// It returns the whole `store[storeKey].bucketing` map (experienceId → variationId) for a
    /// visitor, or `[:]` when the store holds no entry for that key. The conversion-tracking path
    /// reads it to populate `ConversionEventData.bucketingData`. It is read-only and does NOT bump
    /// LRU recency (distinct from `stickyVariationId`, which touches) — but recency is the
    /// `lruReadUpdatesRecency` test's concern; here we pin the returned MAP for both a seeded key
    /// and an absent one in one shared-setup test (no copy-paste — SonarQube CPD is token-based).
    @Test("bucketingDecisions returns the full per-visitor map, or empty for an unknown storeKey")
    func bucketingDecisionsReturnsFullMapOrEmpty() async {
        let store = makeDecisionStore()

        await store.saveDecision(variationId: "var-1", experienceId: "exp-1", storeKey: "acc-proj-v1")
        await store.saveDecision(variationId: "var-2", experienceId: "exp-2", storeKey: "acc-proj-v1")

        let decisions = await store.bucketingDecisions(forStoreKey: "acc-proj-v1")
        #expect(decisions == ["exp-1": "var-1", "exp-2": "var-2"], "must return the whole bucketing map")

        let absent = await store.bucketingDecisions(forStoreKey: "acc-proj-none")
        #expect(absent == [:], "an unknown storeKey must return an empty map, not nil/crash")
    }

    // MARK: LRU eviction

    @Test("at capacity, the oldest-accessed storeKey is evicted on a new insert")
    func lruEvictionAtCap() async {
        let store = makeDecisionStore(maxEntries: 2)

        await store.saveDecision(variationId: "var-1", experienceId: "exp-1", storeKey: "key1")
        await store.saveDecision(variationId: "var-2", experienceId: "exp-1", storeKey: "key2")
        await store.saveDecision(variationId: "var-3", experienceId: "exp-1", storeKey: "key3")

        // key1 was the least-recently-accessed when key3 was inserted at cap → evicted.
        let evicted = await store.stickyVariationId(forExperience: "exp-1", storeKey: "key1")
        #expect(evicted == nil)
    }

    @Test("a read refreshes recency, so the now-least-recently-used key is evicted instead")
    func lruReadUpdatesRecency() async {
        let store = makeDecisionStore(maxEntries: 2)

        await store.saveDecision(variationId: "var-1", experienceId: "exp-1", storeKey: "key1")
        await store.saveDecision(variationId: "var-2", experienceId: "exp-1", storeKey: "key2")

        // READ key1 — a sticky HIT must bump key1 to most-recently-used, making key2 the LRU.
        let hit = await store.stickyVariationId(forExperience: "exp-1", storeKey: "key1")
        #expect(hit == "var-1")

        // Inserting key3 at cap must now evict key2 (the LRU), NOT key1.
        await store.saveDecision(variationId: "var-3", experienceId: "exp-1", storeKey: "key3")

        let key1StillPresent = await store.stickyVariationId(forExperience: "exp-1", storeKey: "key1")
        let key2Evicted = await store.stickyVariationId(forExperience: "exp-1", storeKey: "key2")
        #expect(key1StillPresent == "var-1")
        #expect(key2Evicted == nil)
    }

    @Test("LRU recency survives a reload: the persisted access order, not Dictionary.keys, drives post-reload eviction")
    func lruOrderSurvivesReload() async {
        // One shared backing store: two DecisionStores over the SAME MockFileStore instance read
        // and write the same persisted bytes, because the on-disk URL the store resolves is stable.
        let fileStore = MockFileStore()
        let first = makeDecisionStore(fileStore: fileStore, maxEntries: 2)
        await first.loadFromDisk()

        // Establish the persisted LRU order purely through saves (which DO persist): saving k1
        // again after k2 bumps k1 to most-recently-used, so the persisted access order is [k2, k1]
        // — k2 is least-recently-used. (A read would bump recency in memory but is NOT persisted,
        // so the order must be driven by saves to be observable post-reload.)
        await first.saveDecision(variationId: "var-1", experienceId: "exp-1", storeKey: "k1")
        await first.saveDecision(variationId: "var-2", experienceId: "exp-1", storeKey: "k2")
        await first.saveDecision(variationId: "var-1b", experienceId: "exp-1", storeKey: "k1")

        // Second store over the SAME backing: hydrates from the bytes the first store wrote,
        // INCLUDING the persisted access order [k2, k1] (once accessOrder is persisted).
        let second = makeDecisionStore(fileStore: fileStore, maxEntries: 2)
        await second.loadFromDisk()

        // Inserting a NEW key at cap must evict the least-recently-used PERSISTED key (k2), not an
        // arbitrary key picked from Dictionary.keys order. Against the unfixed impl this is
        // nondeterministic (it may evict k1); after persisting accessOrder it is deterministic.
        await second.saveDecision(variationId: "var-3", experienceId: "exp-1", storeKey: "k3")

        let k2Evicted = await second.stickyVariationId(forExperience: "exp-1", storeKey: "k2")
        let k1StillPresent = await second.stickyVariationId(forExperience: "exp-1", storeKey: "k1")
        #expect(k2Evicted == nil)
        #expect(k1StillPresent == "var-1b")
    }

    // MARK: Corruption recovery

    @Test("loadFromDisk on corrupt bytes leaves the store empty, logs warn, and never throws")
    func corruptionRecoveryEmptyNoThrow() async {
        // `corruptAllReads` makes EVERY read return invalid JSON regardless of the internal URL
        // the store computes — robust to the opaque on-disk path (see MockFileStore docs).
        let logger = MockLogger()
        let fileStore = MockFileStore(corruptAllReads: Data("not-valid-json".utf8))
        let store = makeDecisionStore(logger: logger, fileStore: fileStore)

        // Must not throw: completing this call is itself part of the assertion.
        await store.loadFromDisk()

        // Decode failure → store stays empty.
        let sticky = await store.stickyVariationId(forExperience: "exp-1", storeKey: "acc-proj-v1")
        #expect(sticky == nil)

        // A warn-level line records the recovery (contract: warn-equivalent on decode failure).
        let warnings = logger.entries().filter { $0.level == .warn }
        #expect(!warnings.isEmpty)
    }

    // MARK: StoreData codable round-trip

    @Test("StoreData.bucketing survives a JSON encode / decode round-trip")
    func storeDataBucketingRoundTrips() throws {
        let original = makeStoreData(bucketing: ["exp-1": "var-a"])

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoreData.self, from: encoded)

        #expect(decoded.bucketing["exp-1"] == "var-a")
    }

    // MARK: - Backward-compatible decode (AC6, bd-pi8)

    /// RED-phase contract for AC6: a persisted `StoreData` JSON that PRE-DATES the `segments` and
    /// `locations` fields (written by an SDK ≤ 4.4) must decode WITHOUT throwing, defaulting the
    /// absent fields to `Segments()` and `[:]`. `StoreData` currently uses SYNTHESIZED Codable, so
    /// its decoder calls `decode(_:forKey:)` (not `decodeIfPresent`) for the non-optional `segments`
    /// and `locations` — meaning JSON missing those keys throws `keyNotFound` TODAY. These two tests
    /// MUST FAIL (decode throws) until BE-2 adds a backward-compatible `init(from:)`.
    ///
    /// One decode call site for the two pre-4.4 fixtures so neither test re-inlines the decoder
    /// (SonarQube CPD is token-based — this keeps the two cases from sharing a duplicate block).
    private func decodeStoreData(fromJSON json: String) throws -> StoreData {
        try JSONDecoder().decode(StoreData.self, from: Data(json.utf8))
    }

    @Test("StoreData decodes pre-4.4 JSON missing segments and locations (backward compat)")
    func storeDataDecodesPre44JSONMissingSegmentsAndLocations() throws {
        // No `segments` key, no `locations` key — the on-disk shape an SDK ≤ 4.4 persisted.
        let decoded = try decodeStoreData(fromJSON: #"{"bucketing":{},"goalTriggered":{}}"#)

        #expect(decoded.bucketing.isEmpty)
        #expect(decoded.goalTriggered.isEmpty)
        #expect(decoded.segments == Segments())
        #expect(decoded.locations.isEmpty)
    }

    @Test("StoreData decodes pre-4.4 JSON with bucketing+goalTriggered data, missing segments")
    func storeDataDecodesPre44JSONWithDataMissingSegments() throws {
        // Pre-4.4 JSON carrying real bucketing + goalTriggered data, still no segments/locations.
        let decoded = try decodeStoreData(
            fromJSON: #"{"bucketing":{"exp-1":"var-a"},"goalTriggered":{"g-1":true}}"#
        )

        #expect(decoded.bucketing["exp-1"] == "var-a")
        #expect(decoded.goalTriggered["g-1"] == true)
        #expect(decoded.segments == Segments())
        #expect(decoded.locations.isEmpty)
    }

    @Test("StoreData full round-trip preserves segments and locations")
    func storeDataRoundTripPreservesSegmentsAndLocations() throws {
        // Construct directly: this case needs non-default segments + locations, which the
        // `makeStoreData(bucketing:)` factory cannot express (it seeds only bucketing).
        let original = StoreData(
            bucketing: ["exp-1": "var-a"],
            goalTriggered: ["g-1": true],
            segments: Segments(country: "DE"),
            locations: ["loc-1": "active"]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoreData.self, from: encoded)

        #expect(decoded.bucketing["exp-1"] == "var-a")
        #expect(decoded.goalTriggered["g-1"] == true)
        #expect(decoded.segments.country == "DE")
        #expect(decoded.locations["loc-1"] == "active")
    }

    // MARK: - Goal dedup (Story 4.3)

    /// RED-phase contract for the NEW `markGoalTriggeredIfNeeded(goalId:forVisitorKey:)` (does NOT
    /// exist yet): `func markGoalTriggeredIfNeeded(goalId: String, forVisitorKey: String) async -> Bool`.
    /// It returns `true` the FIRST time a `(visitorKey, goalId)` pair is seen — marking the goal in
    /// that key's `StoreData.goalTriggered[goalId]` and persisting the whole store exactly like
    /// ``saveDecision(variationId:experienceId:storeKey:)`` — and `false` on every repeat. The dedup
    /// key is the `(visitorKey, goalId)` PAIR: different goals under one visitor, and the same goal
    /// under different visitors, are independent (matching the Android dedup-key semantics).

    /// One call site for the method under test so no test inline-repeats the await (SonarQube CPD is
    /// token-based; this keeps the three first/false/independence cases from sharing a duplicate block).
    private func markGoal(_ goalId: String, on store: DecisionStore, key: String) async -> Bool {
        await store.markGoalTriggeredIfNeeded(goalId: goalId, forVisitorKey: key)
    }

    @Test("markGoalTriggeredIfNeeded returns true first call, false second")
    func goalDedupFirstTrueSecondFalse() async {
        let store = makeDecisionStore()
        let key = "acc-proj-v1"

        let firstMark = await markGoal("g-1", on: store, key: key)
        let repeatMark = await markGoal("g-1", on: store, key: key)

        #expect(firstMark == true)
        #expect(repeatMark == false)
    }

    @Test("a different goal on the same visitor is independent")
    func goalDedupPerGoalWithinVisitor() async {
        let store = makeDecisionStore()
        let key = "acc-proj-v1"

        #expect(await markGoal("g-1", on: store, key: key) == true)
        // g-2 is a distinct goal for the same visitor → not yet triggered.
        #expect(await markGoal("g-2", on: store, key: key) == true)
        // g-1 was already marked above → repeat is deduped.
        #expect(await markGoal("g-1", on: store, key: key) == false)
    }

    @Test("the same goal under a different visitor key is independent")
    func goalDedupPerVisitorKey() async {
        let store = makeDecisionStore()

        #expect(await markGoal("g-1", on: store, key: "k-A") == true)
        // Same goal id, different visitor key → the dedup key includes the visitor, so not deduped.
        #expect(await markGoal("g-1", on: store, key: "k-B") == true)
    }

    @Test("markGoalTriggeredIfNeeded persists across a DecisionStore reload")
    func goalDedupSurvivesReload() async {
        // Two DecisionStores over ONE MockFileStore read/write the same persisted bytes, because
        // the on-disk URL the store resolves is stable. Mirrors `lruOrderSurvivesReload`.
        let fileStore = MockFileStore()
        let first = makeDecisionStore(fileStore: fileStore)
        await first.loadFromDisk()
        _ = await first.markGoalTriggeredIfNeeded(goalId: "g-1", forVisitorKey: "k")

        let second = makeDecisionStore(fileStore: fileStore)
        await second.loadFromDisk()

        // The goal is already triggered in the bytes the first store wrote → still deduped.
        let result = await second.markGoalTriggeredIfNeeded(goalId: "g-1", forVisitorKey: "k")
        #expect(result == false)
    }

    @Test("StoreData.goalTriggered survives a JSON encode/decode round-trip")
    func storeDataGoalTriggeredRoundTrips() throws {
        // `makeStoreData` only seeds bucketing; this case needs a goalTriggered flag, so construct
        // the four-field `StoreData` directly (the one place a test re-inlines the init, by necessity).
        let original = StoreData(bucketing: [:], goalTriggered: ["g-1": true], segments: Segments(), locations: [:])

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoreData.self, from: encoded)

        #expect(decoded.goalTriggered["g-1"] == true)
    }
}
