// Tests/ConvertSwiftSDKCoreTests/Experience/ExperienceManagerTests.swift
// RED-phase suite for `ExperienceManager`. Covers Story 4 (single-experience `selectVariation`:
// AC2 unknown-key / audience+location gating, AC3 sticky short-circuit, AC8 `enableTracking` gates
// the bucketing enqueue, AC9 a NEW decision fires the `.bucketing` EventBus event) AND Story 5
// (bulk `selectVariations` over every config experience with per-call tracking control: empty → [],
// per-experience gate failure excluded without aborting the loop, config-order preservation, and the
// shared `enableTracking` flag threaded into each per-experience bucket).
//
// ── Expected RED state ───────────────────────────────────────────────────────────────────
// The bulk `selectVariations` member does NOT exist yet on `ExperienceManager`, so this file is
// EXPECTED to fail to COMPILE with "value of type 'ExperienceManager' has no member 'selectVariations'"
// (the singular `selectVariation` and every collaborator — `RuleManager`, `BucketingManager`,
// `DecisionStore`, `EventBus`, the `ProjectConfig` fixtures — already exist, so that missing-member
// error is the ONLY one expected).
//
// ── Pipeline contract pinned here (JS-parity for the in-scope subset) ─────────────────────
// Single experience: `fullExperience(forKey:)` miss → nil; storeKey "<accountId>-<projectId>-<visitorId>";
// a sticky hit short-circuits (no enqueue / no fire); empty audience & location sets are unrestricted
// (a non-empty set is evaluated and a fail → nil); the bucket performs the single enqueue when tracking
// is enabled, persists the decision, and fires `.bucketing` only on a NEW decision.
// Bulk: iterate `rawExperiences` in order, call the single path per `.key`, collect non-nil results
// (a nil is excluded, the loop never aborts), thread `enableTracking` straight through; empty/nil → [].
//
// ── Test-hygiene invariants ──────────────────────────────────────────────────────────────
//   * EventBus delivery is asynchronous (`fire` dispatches each callback as a `MainActor` task), so
//     every fired-or-not assertion drains via `await MainActor.run { }` (`drain()`) — NEVER
//     `Task.yield()`. The fire count + payload are captured into a `LockedBox` (the project's
//     `Sendable` lock cell from `MockCorePorts.swift`) so the `@Sendable` callback has no
//     `inout`/actor-capture issue under Swift 6 strict concurrency.
//   * SonarQube 3% `new_duplicated_lines_density`: every manager goes through `makeExperienceManager`,
//     every config through the shared `ProjectConfigFixtures`, the single/bulk call contracts through
//     `select`/`selectAll`, and the subscribe-and-capture wiring through `subscribeBucketing` — no
//     ≥10-line block is copy-pasted across cases.

import Foundation
import Testing
@testable import ConvertSwiftSDKCore

@Suite("ExperienceManager")
struct ExperienceManagerTests {

    // MARK: - Shared identifiers (one source of truth; keeps the storeKey contract un-duplicated)

    /// The account/project/visitor triple every scenario buckets under. Centralized so the
    /// `"<accountId>-<projectId>-<visitorId>"` storeKey is assembled in exactly one place
    /// (``Ids/storeKey``) and the call sites stay free of re-spelled literals.
    private enum Ids {
        static let account = "a"
        static let project = "p"
        static let visitor = "v1"
        /// The storeKey the pipeline derives — `<account>-<project>-<visitor>`.
        static let storeKey = "\(account)-\(project)-\(visitor)"
    }

    // MARK: - EventBus capture (a `Sendable` cell the `@Sendable` callback writes under a lock)

    /// What a `.bucketing` EventBus subscriber records: fire count + last payload. A named struct (not
    /// a tuple — `large_tuple`) so a `LockedBox` can hold it for the `@Sendable` callback to mutate.
    private struct BucketingCapture {
        var fireCount = 0
        var lastPayload: BucketingPayload?
    }

    // MARK: - Subject factory (SonarQube 3% new-duplicated-lines gate)

    /// Builds the subject with REAL collaborators wired to the passed (or default) doubles, so no test
    /// re-wires the dependencies inline. The injected `eventSink` is handed to the `BucketingManager`
    /// (which owns the enqueue) and is the SAME `MockEventSink` the test later inspects; `decisionStore`
    /// pre-seeds sticky state and `eventBus` carries the `.bucketing` fire counter.
    private func makeExperienceManager(
        decisionStore: DecisionStore = DecisionStore(logger: MockLogger(), fileStore: MockFileStore()),
        eventSink: MockEventSink = MockEventSink(),
        eventBus: EventBus = EventBus()
    ) -> ExperienceManager {
        ExperienceManager(
            ruleManager: RuleManager(logger: MockLogger()),
            bucketingManager: BucketingManager(eventSink: eventSink, logger: MockLogger()),
            decisionStore: decisionStore,
            eventBus: eventBus,
            logger: MockLogger()
        )
    }

    /// Invokes the single-experience `selectVariation` with the shared ids and per-scenario knobs, so
    /// the long argument list is written once (`attributes` → audience gate, `locationProperties` →
    /// location gate, `enableTracking` → enqueue).
    private func select(
        _ subject: ExperienceManager,
        key: String,
        in config: ProjectConfig,
        attributes: [String: String] = [:],
        locationProperties: [String: String] = [:],
        enableTracking: Bool = true
    ) async -> Variation? {
        await subject.selectVariation(
            forKey: key,
            in: config,
            visitorId: Ids.visitor,
            accountId: Ids.account,
            projectId: Ids.project,
            attributes: attributes,
            locationProperties: locationProperties,
            enableTracking: enableTracking
        )
    }

    /// Invokes the BULK `selectVariations` with the shared ids and per-scenario knobs (the bulk twin of
    /// ``select(_:key:in:attributes:locationProperties:enableTracking:)``). The id triple matches
    /// ``Ids`` so a sticky decision pre-seeded under ``Ids/storeKey`` is honoured by the iteration.
    private func selectAll(
        _ subject: ExperienceManager,
        in config: ProjectConfig,
        attributes: [String: String] = [:],
        locationProperties: [String: String] = [:],
        enableTracking: Bool = true
    ) async -> [Variation] {
        await subject.selectVariations(
            in: config,
            visitorId: Ids.visitor,
            accountId: Ids.account,
            projectId: Ids.project,
            attributes: attributes,
            locationProperties: locationProperties,
            enableTracking: enableTracking
        )
    }

    /// Lets already-dispatched `MainActor` callbacks run before assertions read the capture.
    /// `EventBus.fire` delivers each callback as a `Task { @MainActor in … }`, so `await MainActor.run`
    /// enqueues a barrier behind them on the serial/FIFO `MainActor` executor — it completes only after
    /// every prior callback has run. `Task.yield()` does NOT suffice (cooperative pool, not that
    /// executor). Pure executor barrier, no wall-clock wait; mirrors `EventBusTests.drain()` verbatim.
    private func drain() async {
        await MainActor.run { }
    }

    /// Subscribes a `.bucketing` counter on `eventBus`, returning the `LockedBox` the callback writes —
    /// the caller fires, `await drain()`s, then reads `.get.fireCount` / `.get.lastPayload`. Centralized
    /// so no test re-spells the subscribe-and-capture wiring.
    private func subscribeBucketing(on eventBus: EventBus) async -> LockedBox<BucketingCapture> {
        let box = LockedBox(BucketingCapture())
        _ = await eventBus.on(.bucketing) { payload in
            box.withLock { capture in
                capture.fireCount += 1
                if case let .bucketing(bucketing) = payload {
                    capture.lastPayload = bucketing
                }
            }
        }
        return box
    }

    /// `selectVariation(forKey:)` for a key absent from the config returns nil (the
    /// `fullExperience(forKey:)` miss short-circuits before any gate or bucket).
    @Test("AC2 — an unknown experience key returns nil")
    func unknownExperienceKeyReturnsNil() async throws {
        let config = try ProjectConfigFixtures.singleExperienceConfig(key: "known")
        let subject = makeExperienceManager()

        let variation = await select(subject, key: "no-such", in: config)

        #expect(variation == nil)
    }

    /// A pre-seeded sticky decision restores its variation directly: the bucket path is skipped, so NO
    /// event is enqueued and the `.bucketing` subscriber does NOT fire (a sticky hit is not a NEW one).
    @Test("AC3 — a sticky decision short-circuits with no enqueue and no EventBus fire")
    func stickyDecisionShortCircuits() async throws {
        let config = try ProjectConfigFixtures.singleExperienceConfig(
            key: "sticky-exp", variationId: "sticky-var"
        )
        let store = DecisionStore(logger: MockLogger(), fileStore: MockFileStore())
        await store.saveDecision(
            variationId: "sticky-var", experienceId: "exp-1", storeKey: Ids.storeKey
        )
        let sink = MockEventSink()
        let bus = EventBus()
        let subject = makeExperienceManager(decisionStore: store, eventSink: sink, eventBus: bus)
        let fired = await subscribeBucketing(on: bus)

        let variation = await select(subject, key: "sticky-exp", in: config)
        await drain()

        #expect(variation?.id == "sticky-var")
        let events = await sink.recordedEvents()
        #expect(events.isEmpty, "a sticky hit must not enqueue a new bucketing event")
        #expect(fired.get.fireCount == 0, "a sticky hit must not fire the .bucketing system event")
    }

    /// THE parity-critical case: an experience with NO audiences is UNRESTRICTED — the gate is bypassed,
    /// so a 100%-traffic experience buckets for ARBITRARY attributes (NOT rejected for "no match").
    @Test("AC2 — an empty-audience experience runs (empty audience set is unrestricted, not rejected)")
    func emptyAudienceExperienceRuns() async throws {
        let config = try ProjectConfigFixtures.singleExperienceConfig(key: "open-exp")
        let subject = makeExperienceManager()

        let variation = await select(
            subject, key: "open-exp", in: config, attributes: ["anything": "goes"]
        )

        #expect(variation?.id == "var-1", "an empty-audience experience must bucket, not be rejected")
    }

    /// An experience gated on a `country == "US"` audience, called with `["country": "UK"]`, fails the
    /// gate → nil. Because the gate fails BEFORE the bucket step, nothing is enqueued.
    @Test("AC2 — an audience-gate failure returns nil with no event enqueued")
    func audienceFailReturnsNilNoEvent() async throws {
        let config = try ProjectConfigFixtures.countryGatedExperienceConfig(
            key: "gated-exp", countryEquals: "US"
        )
        let sink = MockEventSink()
        let subject = makeExperienceManager(eventSink: sink)

        let variation = await select(
            subject, key: "gated-exp", in: config, attributes: ["country": "UK"]
        )

        #expect(variation == nil, "a failing audience gate must return nil")
        let events = await sink.recordedEvents()
        #expect(events.isEmpty, "no bucketing event may be enqueued when the audience gate fails")
    }

    /// The same `country == "US"`-gated experience, called with `["country": "US"]`, passes the gate
    /// and — being 100% traffic — buckets to a variation.
    @Test("AC2 — an audience-gate pass buckets to a variation")
    func audiencePassBuckets() async throws {
        let config = try ProjectConfigFixtures.countryGatedExperienceConfig(
            key: "gated-exp", countryEquals: "US"
        )
        let subject = makeExperienceManager()

        let variation = await select(
            subject, key: "gated-exp", in: config, attributes: ["country": "US"]
        )

        #expect(variation?.id == "var-1", "a passing audience gate must bucket")
    }

    /// A 100%-traffic no-audience experience selected with `enableTracking: false` still returns a
    /// variation, but `BucketingManager` (which owns the enqueue) emits NO event — proving the flag
    /// flows through to the bucket step.
    @Test("AC8 — enableTracking:false returns a variation but suppresses the bucketing enqueue")
    func enableTrackingFalseSuppressesEvent() async throws {
        let config = try ProjectConfigFixtures.singleExperienceConfig(key: "open-exp")
        let sink = MockEventSink()
        let subject = makeExperienceManager(eventSink: sink)

        let variation = await select(subject, key: "open-exp", in: config, enableTracking: false)

        #expect(variation?.id == "var-1", "a variation is still selected when tracking is off")
        let events = await sink.recordedEvents()
        #expect(events.isEmpty, "enableTracking:false must suppress the bucketing enqueue")
    }

    /// The same experience with `enableTracking: true` enqueues EXACTLY ONE entry, tagged
    /// `"bucketing"` — the single enqueue `BucketingManager` performs (the EM never double-enqueues).
    @Test("AC8 — enableTracking:true enqueues exactly one bucketing event")
    func enableTrackingTrueEnqueuesExactlyOneBucketingEvent() async throws {
        let config = try ProjectConfigFixtures.singleExperienceConfig(key: "open-exp")
        let sink = MockEventSink()
        let subject = makeExperienceManager(eventSink: sink)

        _ = await select(subject, key: "open-exp", in: config, enableTracking: true)

        let events = await sink.recordedEvents()
        #expect(events.count == 1, "exactly one bucketing event must be enqueued")
        #expect(events.first?.eventType == "bucketing", "the enqueued entry must be a bucketing event")
    }

    /// A NEW decision (`enableTracking: true`) fires `.bucketing` EXACTLY ONCE, carrying the resolved
    /// experienceId / variationId / visitorId (drained via the `MainActor` barrier before the read).
    @Test("AC9 — a new decision fires the .bucketing system event once with the resolved ids")
    func newDecisionFiresBucketingSystemEvent() async throws {
        let config = try ProjectConfigFixtures.singleExperienceConfig(key: "open-exp")
        let bus = EventBus()
        let subject = makeExperienceManager(eventBus: bus)
        let fired = await subscribeBucketing(on: bus)

        let variation = await select(subject, key: "open-exp", in: config, enableTracking: true)
        await drain()

        #expect(variation?.id == "var-1")
        let capture = fired.get
        #expect(capture.fireCount == 1, "a new decision must fire the .bucketing event exactly once")
        #expect(capture.lastPayload?.experienceId == "exp-1", "payload must carry the experienceId")
        #expect(capture.lastPayload?.variationId == "var-1", "payload must carry the variationId")
        #expect(capture.lastPayload?.visitorId == Ids.visitor, "payload must carry the visitorId")
    }

    // MARK: - AC8 + AC9: enableTracking:false suppresses the enqueue but STILL fires .bucketing

    /// On a NEW decision `enableTracking: false` gates ONLY the `EventSink` enqueue (AC8), NOT the
    /// `.bucketing` EventBus fire (AC9 — every new decision fires; the sole non-firing case is a
    /// sticky hit). Pinning BOTH sides on one run stops a future change coupling the fire to the flag.
    @Test("AC8/AC9 — enableTracking:false still fires the .bucketing system event but suppresses enqueue")
    func enableTrackingFalseStillFiresBucketingSystemEvent() async throws {
        let config = try ProjectConfigFixtures.singleExperienceConfig(key: "open-exp")
        let sink = MockEventSink()
        let bus = EventBus()
        let subject = makeExperienceManager(eventSink: sink, eventBus: bus)
        let fired = await subscribeBucketing(on: bus)

        let variation = await select(subject, key: "open-exp", in: config, enableTracking: false)
        await drain()

        #expect(variation?.id == "var-1", "a variation is still selected when tracking is off")
        #expect(
            fired.get.fireCount == 1,
            "enableTracking:false must NOT gate the .bucketing system event — it still fires once"
        )
        let events = await sink.recordedEvents()
        #expect(events.isEmpty, "enableTracking:false must still suppress the bucketing enqueue")
    }

    // MARK: - Bulk `selectVariations` (Story 5 — run all experiences, per-call tracking control)
    //
    // Each test goes through ``selectAll`` (the shared bulk-arg wrapper) and a ``ProjectConfigFixtures``
    // builder, so no body re-inlines the call contract or a config envelope (SonarQube 3% gate). The
    // `@Test` display name + inline `#expect` messages carry the per-case contract.

    /// An empty config (nil/empty `rawExperiences`) yields `[]` — nothing to iterate.
    @Test("Bulk — selectVariations over a config with no experiences returns []")
    func selectVariationsEmptyConfigReturnsEmpty() async throws {
        let config = try ProjectConfigFixtures.makeConfig(experiencesJSON: "[]")
        let variations = await selectAll(makeExperienceManager(), in: config)
        #expect(variations.isEmpty, "no experiences must yield no variations")
    }

    /// Of 3 experiences only `"exp-1"` is gated on `country == "US"`; called with `["country":"UK"]`
    /// it fails (nil) and is EXCLUDED while the loop continues — exactly the 2 ungated ones survive,
    /// in config order (exclusion must not reorder).
    @Test("Bulk — a per-experience audience-gate failure is excluded; the loop continues")
    func selectVariationsExcludesAudienceGatedFailure() async throws {
        let config = try ProjectConfigFixtures.multiExperienceConfig(count: 3, gatedFailCountry: "US")
        let variations = await selectAll(makeExperienceManager(), in: config, attributes: ["country": "UK"])
        #expect(variations.count == 2, "the gate-failing experience is excluded; the other two remain")
        #expect(
            variations.map { $0.experienceKey } == ["exp-2", "exp-3"],
            "exclusion must not reorder — the surviving experiences stay in config order"
        )
    }

    /// Over 3 eligible experiences the collected variations preserve `rawExperiences` order.
    @Test("Bulk — selectVariations preserves config order")
    func selectVariationsPreservesConfigOrder() async throws {
        let config = try ProjectConfigFixtures.multiExperienceConfig(count: 3)
        let variations = await selectAll(makeExperienceManager(), in: config)
        #expect(
            variations.map { $0.experienceKey } == ["exp-1", "exp-2", "exp-3"],
            "results must be collected in config order"
        )
    }

    /// `enableTracking: false` is threaded into EVERY per-experience bucket: both variations come
    /// back but the sink records ZERO events.
    @Test("Bulk — enableTracking:false returns the variations but enqueues nothing")
    func selectVariationsTrackingFalseEnqueuesNothing() async throws {
        let config = try ProjectConfigFixtures.multiExperienceConfig(count: 2)
        let sink = MockEventSink()
        let variations = await selectAll(makeExperienceManager(eventSink: sink), in: config, enableTracking: false)
        #expect(variations.count == 2, "both eligible experiences are still selected when tracking is off")
        let events = await sink.recordedEvents()
        #expect(events.isEmpty, "enableTracking:false must suppress every per-experience enqueue")
    }

    /// 2 NEW-decision eligible experiences with `enableTracking: true` enqueue one bucketing event
    /// each — 2 entries, all tagged `"bucketing"`.
    @Test("Bulk — enableTracking:true enqueues one bucketing event per new decision")
    func selectVariationsTrackingTrueEnqueuesPerNewDecision() async throws {
        let config = try ProjectConfigFixtures.multiExperienceConfig(count: 2)
        let sink = MockEventSink()
        _ = await selectAll(makeExperienceManager(eventSink: sink), in: config, enableTracking: true)
        let events = await sink.recordedEvents()
        #expect(events.count == 2, "one bucketing event must be enqueued per new decision")
        #expect(
            events.allSatisfy { $0.eventType == "bucketing" },
            "every enqueued entry must be a bucketing event"
        )
    }

    /// `"exp-1"` (experienceId `"id-1"`, variationId `"var-1"` — the fixture's deterministic ids) is
    /// pre-seeded sticky and `"exp-2"` is new; with `enableTracking: true` only the new decision
    /// enqueues — exactly 1 event (the sticky hit short-circuits without re-enqueueing).
    @Test("Bulk — a pre-seeded sticky experience does not re-enqueue; only the new decision does")
    func selectVariationsStickyDoesNotReEnqueue() async throws {
        let config = try ProjectConfigFixtures.multiExperienceConfig(count: 2)
        let store = DecisionStore(logger: MockLogger(), fileStore: MockFileStore())
        await store.saveDecision(variationId: "var-1", experienceId: "id-1", storeKey: Ids.storeKey)
        let sink = MockEventSink()
        let subject = makeExperienceManager(decisionStore: store, eventSink: sink)

        let variations = await selectAll(subject, in: config, enableTracking: true)

        #expect(variations.count == 2, "the sticky hit and the new decision both yield a variation")
        let events = await sink.recordedEvents()
        #expect(events.count == 1, "the sticky hit must not re-enqueue; only the new decision does")
    }
}
