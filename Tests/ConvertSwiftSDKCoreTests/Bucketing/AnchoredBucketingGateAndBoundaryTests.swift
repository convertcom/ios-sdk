// Tests/ConvertSwiftSDKCoreTests/Bucketing/AnchoredBucketingGateAndBoundaryTests.swift
// Anchored bucketing layout test suite for qs-01 (cross-SDK bucketing contract v12).
// Spec of record: `2026-06-09-convert-ios-sdk/qs-01-anchored-bucketing-layout.md`.
//
// Sibling of `AnchoredBucketingParityTests.swift` (the 59-vector golden-fixture sweep, AC7).
// THIS file covers every AC the fixture sweep alone doesn't isolate:
//   * AC1 — the `version` gate (>11 anchored, <=11/missing packed).
//   * AC4 — stopped-arm zero-width (weight preserved, anchors unmoved) + explicit `ta:0` != 100.
//   * AC5 — NaN/absent-ta defaults to 100.0 weight; totalWeight<=0 -> nil; anchor/width boundary
//     inclusivity (`value == anchor` IN, `value == anchor + width` OUT).
//   * AC6 — the packed pass is not just "produces the same answer" but DELEGATES verbatim.
//   * AC8 — a sticky decision wins over both layouts (a structural lock, not new behavior).
//   * AC9 — a successful anchored bucket preserves the unchanged `.bucketing` event shape.
//
// ── File-scope data types (not nested in the `@Suite` struct) ─────────────────────────────
// `BoundaryVariationSpec`/`BoundaryVector` and the boundary-vector arrays live at file scope so
// the `@Suite` struct's body stays under SwiftLint's `type_body_length` gate, and so the whole
// file stays under `file_length` — splitting data from behavior, not duplicating either.
//
// ── SonarQube `new_duplicated_lines_density` discipline ───────────────────────────────────
// ONE parameterized `@Test(arguments:)` drives the AC1 gate sweep, a SECOND drives the full
// AC4/AC5 boundary sweep — mirroring `BucketingManagerTests.selectBucketAccumulateFirstWins` for
// the packed selector. Every manager goes through `makeManager`.

import Foundation
import Testing
@testable import ConvertSwiftSDKCore

/// One hand-built ANCHORED scenario: a variation spec plus the `value` to select at and the
/// expected result — a named struct (not a tuple) so `large_tuple` stays satisfied.
struct BoundaryVariationSpec: Sendable {
    let id: String
    let trafficAllocation: Double?
    let status: Components.Schemas.VariationStatuses?
}

/// One direct `AnchoredBucketing.selectBucket` boundary vector — hand-computed from the spec's
/// normative pseudocode (NOT derived from the golden-vector fixture, which already covers the
/// end-to-end hash-driven path; these isolate the pure per-value selection math at controlled
/// `value`s the fixture cannot target directly).
struct AnchoredBoundaryVector: Sendable {
    let description: String
    let variations: [BoundaryVariationSpec]
    let value: Int
    let expected: String?
}

/// Two arms, 30/70 split, both `running`. `totalWeight = 100`; A covers `[0,3000)`, B covers
/// `[3000,10000)` — exercises AC5's `value == anchor` (IN) / `value == anchor + width` (OUT)
/// boundary at the shared edge (`3000`), where A's upper bound and B's anchor coincide.
private let thirtySeventyBoundaries: [AnchoredBoundaryVector] = [
    AnchoredBoundaryVector(
        description: "AC5 — value == A's anchor (0) is IN",
        variations: [
            BoundaryVariationSpec(id: "A", trafficAllocation: 30, status: .running),
            BoundaryVariationSpec(id: "B", trafficAllocation: 70, status: .running)
        ],
        value: 0,
        expected: "A"
    ),
    AnchoredBoundaryVector(
        description: "AC5 — value just below A's anchor + width (2999) is still IN for A",
        variations: [
            BoundaryVariationSpec(id: "A", trafficAllocation: 30, status: .running),
            BoundaryVariationSpec(id: "B", trafficAllocation: 70, status: .running)
        ],
        value: 2_999,
        expected: "A"
    ),
    AnchoredBoundaryVector(
        description: "AC5 — value == A's anchor + width (3000) is OUT for A and IN for B "
            + "(B's anchor coincides at 3000)",
        variations: [
            BoundaryVariationSpec(id: "A", trafficAllocation: 30, status: .running),
            BoundaryVariationSpec(id: "B", trafficAllocation: 70, status: .running)
        ],
        value: 3_000,
        expected: "B"
    ),
    AnchoredBoundaryVector(
        description: "AC5 — value at the top edge of the bucket space (9999) is IN for B",
        variations: [
            BoundaryVariationSpec(id: "A", trafficAllocation: 30, status: .running),
            BoundaryVariationSpec(id: "B", trafficAllocation: 70, status: .running)
        ],
        value: 9_999,
        expected: "B"
    )
]

/// Three arms 30/30/40; B is `stopped` (ta preserved). AC4: B keeps its WEIGHT (C's anchor still
/// lands at 6000, as if B were active) but gets ZERO width — so `[3000,6000)` is a dead zone
/// (not-bucketed), never reassigned to A or C.
private let stoppedArmBoundaries: [AnchoredBoundaryVector] = [
    AnchoredBoundaryVector(
        description: "AC4 — value just below the stopped arm's anchor (2999) is IN for A",
        variations: [
            BoundaryVariationSpec(id: "A", trafficAllocation: 30, status: .running),
            BoundaryVariationSpec(id: "B", trafficAllocation: 30, status: .stopped),
            BoundaryVariationSpec(id: "C", trafficAllocation: 40, status: .running)
        ],
        value: 2_999,
        expected: "A"
    ),
    AnchoredBoundaryVector(
        description: "AC4 — value at the stopped arm's anchor (3000) falls in its zero-width "
            + "dead zone -> not bucketed; the anchor did NOT move to close the gap",
        variations: [
            BoundaryVariationSpec(id: "A", trafficAllocation: 30, status: .running),
            BoundaryVariationSpec(id: "B", trafficAllocation: 30, status: .stopped),
            BoundaryVariationSpec(id: "C", trafficAllocation: 40, status: .running)
        ],
        value: 3_000,
        expected: nil
    ),
    AnchoredBoundaryVector(
        description: "AC4 — the dead zone persists right up to the next active arm's anchor (5999)",
        variations: [
            BoundaryVariationSpec(id: "A", trafficAllocation: 30, status: .running),
            BoundaryVariationSpec(id: "B", trafficAllocation: 30, status: .stopped),
            BoundaryVariationSpec(id: "C", trafficAllocation: 40, status: .running)
        ],
        value: 5_999,
        expected: nil
    ),
    AnchoredBoundaryVector(
        description: "AC4 — C's anchor (6000) starts exactly where B's PRESERVED weight ends -> IN",
        variations: [
            BoundaryVariationSpec(id: "A", trafficAllocation: 30, status: .running),
            BoundaryVariationSpec(id: "B", trafficAllocation: 30, status: .stopped),
            BoundaryVariationSpec(id: "C", trafficAllocation: 40, status: .running)
        ],
        value: 6_000,
        expected: "C"
    )
]

/// AC4 (explicit `ta: 0`, never `stopped`) + AC5 (NaN/absent default, and totalWeight <= 0).
private let defaultAndZeroWeightBoundaries: [AnchoredBoundaryVector] = [
    AnchoredBoundaryVector(
        description: "AC4 — explicit ta:0 (status running, NOT stopped) is ZERO width, never "
            + "100: the whole space falls to B",
        variations: [
            BoundaryVariationSpec(id: "A", trafficAllocation: 0, status: .running),
            BoundaryVariationSpec(id: "B", trafficAllocation: 100, status: .running)
        ],
        value: 0,
        expected: "B"
    ),
    AnchoredBoundaryVector(
        description: "AC5 — NaN/absent traffic_allocation defaults to 100.0 weight: a sole "
            + "omitted-ta arm covers the whole space",
        variations: [
            BoundaryVariationSpec(id: "SOLE", trafficAllocation: nil, status: .running)
        ],
        value: 9_999,
        expected: "SOLE"
    ),
    AnchoredBoundaryVector(
        description: "AC5 — totalWeight <= 0 (all-zero arms) is not-bucketed regardless of value",
        variations: [
            BoundaryVariationSpec(id: "A", trafficAllocation: 0, status: .running),
            BoundaryVariationSpec(id: "B", trafficAllocation: 0, status: .stopped)
        ],
        value: 0,
        expected: nil
    )
]

/// The full AC4/AC5 boundary sweep — every scenario above, in one flat array.
private let anchoredBoundaryVectors: [AnchoredBoundaryVector] =
    thirtySeventyBoundaries + stoppedArmBoundaries + defaultAndZeroWeightBoundaries

@Suite("AnchoredBucketingGateAndBoundary")
struct AnchoredBucketingGateAndBoundaryTests {

    // MARK: - Shared builders (SonarQube 3% new-duplicated-lines gate)

    /// Builds the subject with a recording event sink and a no-op logger — every test that needs
    /// a manager goes through this so construction is declared exactly once.
    private func makeManager(eventSink: MockEventSink = MockEventSink()) -> BucketingManager {
        BucketingManager(eventSink: eventSink, logger: MockLogger())
    }

    /// A single-variation, single-arm, sole-100%-allocation `running` experience at the given
    /// `version` — used by both the AC1 gate-branching sweep and the AC9 event-shape test. A
    /// 100%-allocation arm is guaranteed to bucket EVERY visitor under both layouts (packed:
    /// `[0,10000)`; anchored: anchor `0`, width `10000`), so it isolates "did the gate route
    /// somewhere that buckets" from any hash/weight-math edge case.
    private func makeSingleFullAllocationExperience(version: Double?) -> Components.Schemas.ConfigExperience {
        Components.Schemas.ConfigExperience(
            id: "gate-exp",
            version: version,
            variations: [
                Components.Schemas.ExperienceVariationConfig(
                    id: "only", traffic_allocation: 100, status: .running
                )
            ]
        )
    }

    /// Builds the `ExperienceVariationConfig` array a boundary vector describes.
    private func makeVariations(_ specs: [BoundaryVariationSpec]) -> [Components.Schemas.ExperienceVariationConfig] {
        specs.map { spec in
            Components.Schemas.ExperienceVariationConfig(
                id: spec.id, traffic_allocation: spec.trafficAllocation, status: spec.status
            )
        }
    }

    // MARK: - AC1 — gate branching

    /// AC1: `version > 11` routes to ANCHORED; `version <= 11` or missing routes to PACKED. Every
    /// case uses the sole 100%-allocation arm (see `makeSingleFullAllocationExperience`), whose
    /// correct/final answer is `"only"` under EITHER layout — so a non-`"only"` result proves the
    /// gate routed somewhere broken. The v12 case resolves through the real
    /// `AnchoredBucketing.selectBucket`; the packed cases resolve through AC6's verbatim
    /// delegation to the existing `bucket(...)`.
    @Test(
        "AC1 — version gate: >11 routes to ANCHORED, <=11/missing routes to PACKED",
        arguments: [
            (version: 12.0, label: "v12 (>11) -> anchored"),
            (version: 11.0, label: "v11 -> packed (the inert-on-ship production stamp)"),
            (version: 5.0, label: "v5 (<11) -> packed"),
            (version: nil, label: "missing version -> packed")
        ] as [(version: Double?, label: String)]
    )
    func gateBranchesOnVersion(version: Double?, label: String) async {
        let experience = makeSingleFullAllocationExperience(version: version)
        let manager = makeManager()
        let result = await manager.bucketVersionGated(
            visitorId: "any-visitor", experience: experience, enableTracking: false
        )
        #expect(result?.id == "only", Comment(rawValue: label))
    }

    // MARK: - AC4 / AC5 — anchored selector boundaries, defaults, and stops

    /// AC4/AC5, driven directly against the pure `AnchoredBucketing.selectBucket` selector (no
    /// hash, no `BucketingManager`) at hand-picked `value`s the golden-vector fixture cannot
    /// target precisely. Every case — whether `expected` is a real variation id or `nil` —
    /// resolves through the real anchored selector.
    @Test(
        "AC4/AC5 — anchored selector boundaries, defaults, and stops",
        arguments: anchoredBoundaryVectors
    )
    func anchoredBoundaries(_ vector: AnchoredBoundaryVector) {
        let selected = AnchoredBucketing.selectBucket(
            variations: makeVariations(vector.variations), value: vector.value
        )
        #expect(selected == vector.expected, Comment(rawValue: vector.description))
    }

    // MARK: - AC6 — packed regression lock (delegation, not just outcome)

    /// AC6: for `version <= 11`, `bucketVersionGated` must delegate VERBATIM to the existing
    /// `bucket(...)` — not merely produce the same answer by coincidence. Calling both with the
    /// same experience/visitor and asserting identical results locks the delegation itself.
    @Test("AC6 — v11 delegates verbatim: bucketVersionGated matches bucket() bit-for-bit")
    func packedRegressionLockDelegatesVerbatim() async {
        let experience = Components.Schemas.ConfigExperience(
            id: "pack-exp",
            version: 11,
            variations: [
                Components.Schemas.ExperienceVariationConfig(id: "a", traffic_allocation: 50, status: .running),
                Components.Schemas.ExperienceVariationConfig(id: "b", traffic_allocation: 50, status: .running)
            ]
        )
        let manager = makeManager()
        let direct = await manager.bucket(visitorId: "visitor-x", experience: experience, enableTracking: false)
        let gated = await manager.bucketVersionGated(
            visitorId: "visitor-x", experience: experience, enableTracking: false
        )
        #expect(gated?.id == direct?.id, "v11 must route bucketVersionGated -> bucket() untouched")
    }

    // MARK: - AC8 — sticky decision wins over both layouts

    /// AC8: a pre-seeded sticky decision short-circuits `ExperienceManager.selectVariation` at
    /// step 2, strictly BEFORE step 5's bucket call — so it wins regardless of which layout step 5
    /// would otherwise have run. This is a STRUCTURAL guarantee already true today
    /// (`selectVariation` never even inspects `experience.version` before the sticky check), and
    /// stays true once Phase 2 rewires step 5 to call `bucketVersionGated` instead of `bucket()`
    /// directly — the sticky check sits strictly earlier in the pipeline either way. Passes today;
    /// it is a lock, not a new-behavior assertion.
    @Test("AC8 — a stored (sticky) decision wins over both bucketing layouts")
    func stickyDecisionWinsOverBothLayouts() async throws {
        let config = try ProjectConfigFixtures.singleExperienceConfig(
            experienceId: "exp-1", key: "sticky-exp", variationId: "sticky-var"
        )
        let store = DecisionStore(logger: MockLogger(), fileStore: MockFileStore())
        await store.saveDecision(variationId: "sticky-var", experienceId: "exp-1", storeKey: "a-p-v1")
        let sink = MockEventSink()
        let subject = ExperienceManager(
            ruleManager: RuleManager(logger: MockLogger()),
            bucketingManager: BucketingManager(eventSink: sink, logger: MockLogger()),
            decisionStore: store,
            eventBus: EventBus(),
            logger: MockLogger()
        )

        let variation = await subject.selectVariation(
            forKey: "sticky-exp",
            in: config,
            visitorId: "v1",
            accountId: "a",
            projectId: "p",
            attributes: [:],
            locationProperties: [:],
            enableTracking: true
        )

        #expect(variation?.id == "sticky-var")
        let events = await sink.recordedEvents()
        #expect(events.isEmpty, "a sticky hit must never reach ANY bucketing pass (packed or anchored)")
    }

    // MARK: - AC9 — no event/API drift

    /// AC9: a successful ANCHORED bucket must enqueue exactly ONE `.bucketing`-tagged event —
    /// same shape as the packed pass. The real selector resolves the variation, and
    /// `bucketVersionGated`'s result-mapping/enqueue plumbing emits the event on that success.
    @Test("AC9 — a successful anchored bucket enqueues exactly one unchanged-shape bucketing event")
    func anchoredBucketPreservesEventShape() async {
        let sink = MockEventSink()
        let experience = makeSingleFullAllocationExperience(version: 12)
        let manager = makeManager(eventSink: sink)

        let variation = await manager.bucketVersionGated(
            visitorId: "any-visitor", experience: experience, enableTracking: true
        )

        #expect(variation?.id == "only")
        let events = await sink.recordedEvents()
        #expect(events.count == 1)
        #expect(events.first?.eventType == "bucketing")
    }
}
