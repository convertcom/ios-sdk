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
}
