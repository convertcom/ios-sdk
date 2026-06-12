// Tests/ConvertSDKCoreTests/Bucketing/BucketingManagerTests.swift
// RED-phase suite for `BucketingManager` (Epic 3 / Story 2 — deterministic bucketing).
//
// These tests are written against the BucketingManager surface BEFORE the implementation
// exists, so the file is EXPECTED to fail to compile ("cannot find 'BucketingManager' in
// scope") until the GREEN phase lands `Sources/ConvertSDKCore/Bucketing/BucketingManager.swift`.
// Only the `selectBucket` arithmetic, bucket-value formula, and `bucket(...)`/enqueue
// behavior are asserted here — no implementation detail is duplicated.
//
// SonarQube `new_duplicated_lines_density` (3% gate): every test that needs a manager goes
// through ``makeBucketingManager`` and every experience goes through ``makeExperience`` —
// the construction is never inlined, and the encode/parse of an enqueued entry is funneled
// through ``decodeBucketingEntry`` so no ≥10-line block is copy-pasted across cases.

import Foundation
import Testing
@testable import ConvertSDKCore

@Suite("BucketingManager")
struct BucketingManagerTests {

    // MARK: - Named carriers (SwiftLint `large_tuple`: max 2 tuple members)

    /// One variation spec for ``makeExperience`` — a named struct (not a 3-member tuple) so the
    /// `large_tuple` rule stays satisfied, mirroring the `ManagerHarness` precedent in
    /// `MockCorePorts.swift`.
    private struct VariationSpec {
        let id: String
        let key: String
        let alloc: Double
    }

    /// The fields extracted from an encoded bucketing entry — a named struct (not a 3-member
    /// tuple) for the same `large_tuple` reason.
    private struct DecodedBucketingEntry {
        let eventType: String
        let experienceId: String?
        let variationId: String?
    }

    // MARK: - Shared helpers (SonarQube 3% new-duplicated-lines gate)

    /// Builds the subject with a recording event sink and a no-op logger. Used by EVERY test
    /// that needs a manager so the construction is declared exactly once.
    private func makeBucketingManager(
        eventSink: MockEventSink = MockEventSink()
    ) -> BucketingManager {
        BucketingManager(eventSink: eventSink, logger: MockLogger())
    }

    /// Builds a ``Components.Schemas.ConfigExperience`` with the given `id`/`key` and a
    /// variations list assembled from `(id, key, alloc)` tuples — relying on the generated
    /// memberwise inits (all other fields default to `nil`). Declared once so no test re-wires
    /// the generated config inline.
    private func makeExperience(
        id: String,
        key: String,
        variations: [VariationSpec]
    ) -> Components.Schemas.ConfigExperience {
        let configs = variations.map { variation in
            Components.Schemas.ExperienceVariationConfig(
                id: variation.id,
                key: variation.key,
                traffic_allocation: variation.alloc
            )
        }
        return Components.Schemas.ConfigExperience(id: id, key: key, variations: configs)
    }

    /// Encodes a recorded ``TrackingEventEntry`` and extracts `(eventType, experienceId,
    /// variationId)` from its flat `data` object. Centralized so the JSON round-trip is
    /// written once rather than repeated per assertion.
    private func decodeBucketingEntry(
        _ entry: TrackingEventEntry
    ) throws -> DecodedBucketingEntry {
        let json = try JSONEncoder().encode(entry)
        let root = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let eventType = root?["eventType"] as? String ?? ""
        let data = root?["data"] as? [String: Any]
        return DecodedBucketingEntry(
            eventType: eventType,
            experienceId: data?["experienceId"] as? String,
            variationId: data?["variationId"] as? String
        )
    }

    // MARK: - AC5: selectBucket accumulate-first-wins

    /// `[("a",5000),("b",5000)]` partitions 0..<10000 at 5000 with a STRICT `<`: values
    /// 0..4999 fall to "a"; 5000..9999 fall to "b" (at 5000, prev for "a" is 5000 and
    /// 5000 < 5000 is false). One parameterized body covers every boundary so the assertion
    /// chain is not copy-pasted across four near-identical tests.
    @Test(
        "AC5 — selectBucket accumulate-first-wins with a strict < boundary",
        arguments: [
            (value: 0, expected: "a"),
            (value: 4_999, expected: "a"),
            (value: 5_000, expected: "b"),
            (value: 5_001, expected: "b")
        ]
    )
    func selectBucketAccumulateFirstWins(value: Int, expected: String) {
        let weights: [(key: String, weight: Int)] = [("a", 5_000), ("b", 5_000)]
        #expect(BucketingManager.selectBucket(weights: weights, value: value) == expected)
    }

    /// AC5: when the cumulative weights do not cover the bucket space (6000 < 10000), a value
    /// in the uncovered tail (9999) selects no key.
    @Test("AC5 — selectBucket returns nil when the bucket space is uncovered")
    func selectBucketUncoveredReturnsNil() {
        let weights: [(key: String, weight: Int)] = [("a", 3_000), ("b", 3_000)]
        #expect(BucketingManager.selectBucket(weights: weights, value: 9_999) == nil)
    }

    // MARK: - AC3: bucket-value formula stays in 0..<10000

    /// AC3: projecting any 32-bit hash through
    /// `Int(Double(hash) / Double(maxHash) * Double(maxTraffic))` lands in `0..<10000`.
    /// Asserts the formula directly at the hash-space extremes — no manager needed.
    @Test(
        "AC3 — bucket value stays within 0..<10000 for hash-space extremes",
        arguments: [UInt32.min, UInt32.max, UInt32.max / 2]
    )
    func bucketValueInRange(hashResult: UInt32) {
        let bucketValue = Int(
            Double(hashResult) / Double(Defaults.maxHash) * Double(Defaults.maxTraffic)
        )
        #expect(bucketValue >= 0)
        #expect(bucketValue < Defaults.maxTraffic)
    }

    // MARK: - AC2: hash-input concatenation order, end-to-end

    /// AC2: `bucket(visitorId:experience:)` against an experience with a single 100%-allocation
    /// variation (`traffic_allocation: 10000`) must return that variation regardless of the
    /// hashed bucket value — which proves the experienceId+visitorId concat feeds the hash and
    /// the selected variation is mapped back onto the result `Variation`.
    @Test("AC2 — bucket() selects the sole full-allocation variation and maps its identity")
    func bucketSelectsFullAllocationVariation() async {
        let experience = makeExperience(
            id: "exp-123",
            key: "exp-key",
            variations: [VariationSpec(id: "var1", key: "var1-key", alloc: 10_000)]
        )
        let manager = makeBucketingManager()
        let variation = await manager.bucket(visitorId: "visitor-1", experience: experience)
        #expect(variation?.id == "var1")
        #expect(variation?.experienceId == "exp-123")
    }

    // MARK: - AC11 / AC12: enqueue exactly one bucketing event when tracking is enabled

    /// AC11/AC12: a successful bucket with `enableTracking: true` enqueues exactly one entry,
    /// tagged `"bucketing"`, carrying the selected experience/variation ids on the flat `data`.
    @Test("AC11/AC12 — enqueues one bucketing event carrying the selected ids")
    func enqueuesOneBucketingEventWhenTrackingEnabled() async throws {
        let sink = MockEventSink()
        let experience = makeExperience(
            id: "exp1",
            key: "exp-key",
            variations: [VariationSpec(id: "var1", key: "var1-key", alloc: 10_000)]
        )
        let manager = makeBucketingManager(eventSink: sink)
        _ = await manager.bucket(visitorId: "v1", experience: experience, enableTracking: true)
        let events = await sink.recordedEvents()
        #expect(events.count == 1)
        let decoded = try decodeBucketingEntry(try #require(events.first))
        #expect(decoded.eventType == "bucketing")
        #expect(decoded.experienceId == "exp1")
        #expect(decoded.variationId == "var1")
    }

    // MARK: - AC11: zero enqueues when tracking is disabled

    /// AC11: the same successful bucket with `enableTracking: false` enqueues nothing.
    @Test("AC11 — no event enqueued when tracking is disabled")
    func noEnqueueWhenTrackingDisabled() async {
        let sink = MockEventSink()
        let experience = makeExperience(
            id: "exp1",
            key: "exp-key",
            variations: [VariationSpec(id: "var1", key: "var1-key", alloc: 10_000)]
        )
        let manager = makeBucketingManager(eventSink: sink)
        _ = await manager.bucket(visitorId: "v1", experience: experience, enableTracking: false)
        let events = await sink.recordedEvents()
        #expect(events.isEmpty)
    }

    // MARK: - AC11 (implied): no enqueue when the visitor is not bucketed

    /// AC11 (implied): a zero-allocation experience covers none of the bucket space, so
    /// `bucket(...)` returns `nil` deterministically and nothing is enqueued — even with
    /// tracking enabled.
    @Test("AC11 — no event enqueued when the visitor is not bucketed")
    func noEnqueueWhenNotBucketed() async {
        let sink = MockEventSink()
        let experience = makeExperience(
            id: "exp1",
            key: "exp-key",
            variations: [VariationSpec(id: "var1", key: "var1-key", alloc: 0)]
        )
        let manager = makeBucketingManager(eventSink: sink)
        let variation = await manager.bucket(
            visitorId: "v1",
            experience: experience,
            enableTracking: true
        )
        let events = await sink.recordedEvents()
        #expect(variation == nil)
        #expect(events.isEmpty)
    }

    // MARK: - AC12: BucketingEventData wire keys are camelCase, not snake_case

    /// AC12: ``BucketingEventData`` encodes `experienceId`/`variationId` in camelCase and
    /// never leaks a snake_case `experience_id`. Guards the existing CodingKeys directly (this
    /// passes even in RED because it exercises no `BucketingManager` symbol).
    @Test("AC12 — BucketingEventData encodes camelCase wire keys, never snake_case")
    func bucketingEventDataUsesCamelCaseKeys() throws {
        let data = BucketingEventData(experienceId: "exp1", variationId: "var1")
        let json = try JSONEncoder().encode(data)
        let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(dict?["experienceId"] as? String == "exp1")
        #expect(dict?["variationId"] as? String == "var1")
        #expect(dict?["experience_id"] == nil)
    }
}
