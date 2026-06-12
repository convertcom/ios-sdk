// Tests/ConvertSDKCoreTests/Experience/ExperienceManagerTests.swift
// RED-phase suite for `ExperienceManager` (Epic 3 / Story 4 — sticky variation assignment +
// running a single experience). Covers AC2 (unknown key / audience+location gating), AC3 (sticky
// short-circuit), AC8 (`enableTracking` controls the bucketing enqueue), AC9 (a NEW decision fires
// the `.bucketing` system event on the `EventBus`).
//
// ── Expected RED state ───────────────────────────────────────────────────────────────────
// `ExperienceManager` does NOT exist yet (`Sources/ConvertSDKCore/Experience/ExperienceManager.swift`
// is unwritten), so this file is EXPECTED to fail to COMPILE with "cannot find 'ExperienceManager'
// in scope". That is the correct RED signal — the expectations below DEFINE the pipeline contract
// the GREEN implementer must satisfy. Every collaborator (`RuleManager`, `BucketingManager`,
// `DecisionStore`, `EventBus`, the `ProjectConfig` fixtures) already exists, so the ONLY compile
// errors must be the `ExperienceManager`-absence ones.
//
// ── Pipeline contract pinned here (JS-parity for the in-scope subset) ─────────────────────
//   1. `fullExperience(forKey:)` miss → nil.
//   2. storeKey = "<accountId>-<projectId>-<visitorId>".
//   3. STICKY: a non-nil `decisionStore.stickyVariationId` short-circuits — the matching variation
//      is rebuilt and returned with NO bucketing enqueue and NO `.bucketing` EventBus fire.
//   4. AUDIENCE gate: an EMPTY resolved audience set is UNRESTRICTED (passes); a non-empty set is
//      flattened + evaluated against `attributes`, and a fail returns nil.
//   5. LOCATION gate: same over locations against `locationProperties` (empty ⇒ pass).
//   6. BUCKET via `bucketingManager.bucket(...)` — THIS performs the single enqueue when tracking is
//      enabled; a nil bucket returns nil.
//   7. PERSIST the new decision via `decisionStore.saveDecision`.
//   8. FIRE `.bucketing` on the `EventBus` — only on a NEW decision.
//
// ── Test-hygiene invariants ──────────────────────────────────────────────────────────────
//   * EventBus delivery is asynchronous (`fire` dispatches each callback as a `MainActor` task), so
//     every fired-or-not assertion drains via `await MainActor.run { }` — NEVER `Task.yield()`.
//     `drain()` mirrors `EventBusTests.drain()` verbatim (the canonical executor barrier).
//   * `MainActor`-task callbacks are `@Sendable`; the fire count + payload are captured into a
//     `LockedBox` (the project's `Sendable` lock cell from `MockCorePorts.swift`) so the closure has
//     no `inout`/actor-capture issues under Swift 6 strict concurrency.
//   * SonarQube 3% `new_duplicated_lines_density`: every manager goes through `makeExperienceManager`,
//     every config through the shared `ProjectConfigFixtures`, and the subscribe+drain+count pattern
//     through `bucketingFireCount(...)` — no ≥10-line block is copy-pasted across cases.

import Foundation
import Testing
@testable import ConvertSDKCore

@Suite("ExperienceManager")
struct ExperienceManagerTests {

    // MARK: - Shared identifiers (one source of truth; keeps the storeKey contract un-duplicated)

    /// The account/project/visitor triple every scenario buckets under. Centralized so the
    /// `"<accountId>-<projectId>-<visitorId>"` storeKey is assembled in exactly one place
    /// (`seedStoreKey`) and the `selectVariation` call sites stay free of re-spelled literals.
    private enum Ids {
        static let account = "a"
        static let project = "p"
        static let visitor = "v1"
        /// The storeKey the pipeline derives — `<account>-<project>-<visitor>`.
        static let storeKey = "\(account)-\(project)-\(visitor)"
    }

    // MARK: - EventBus capture (a `Sendable` cell the `@Sendable` callback writes under a lock)

    /// What a `.bucketing` EventBus subscriber records: how many times it fired and the last payload
    /// it saw. Held in a `LockedBox` so the `@Sendable` `MainActor` callback can mutate it without an
    /// `inout` capture (a named struct, not a tuple, satisfies `large_tuple`).
    private struct BucketingCapture {
        var fireCount = 0
        var lastPayload: BucketingPayload?
    }

    // MARK: - Subject factory (SonarQube 3% new-duplicated-lines gate)

    /// Builds the subject with REAL collaborators wired to the passed (or default) test doubles, so
    /// no test re-wires the five dependencies inline. The `eventSink` is handed to the
    /// `BucketingManager` (which owns the enqueue) and is the SAME `MockEventSink` the test inspects;
    /// `decisionStore` and `eventBus` are injected so a test can pre-seed sticky state and subscribe a
    /// fire counter respectively.
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

    /// Invokes `selectVariation` with the shared ids and the per-scenario knobs, so the long argument
    /// list is written once. `attributes` drives the audience gate; `locationProperties` the location
    /// gate; `enableTracking` the bucketing enqueue.
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

    /// Lets already-dispatched `MainActor` callbacks run before assertions read the capture.
    ///
    /// `EventBus.fire` delivers each callback as a `Task { @MainActor in … }`, so the drain must
    /// await the `MainActor`'s serial executor — not the cooperative pool. `await MainActor.run { }`
    /// enqueues a barrier job behind the already-hopped callback jobs; because the `MainActor`
    /// executor is serial/FIFO, the barrier completes only after every prior callback has run.
    /// `Task.yield()` does NOT suffice — it yields the cooperative thread and never awaits the
    /// separate `MainActor` executor. Pure executor barrier, no wall-clock wait. Mirrors
    /// `EventBusTests.drain()` verbatim.
    private func drain() async {
        await MainActor.run { }
    }

    /// Subscribes a `.bucketing` counter on `eventBus`, returning the `LockedBox` the callback writes.
    /// The caller fires the pipeline, `await drain()`s, then reads `.get.fireCount` / `.get.lastPayload`.
    /// Centralized so no test re-spells the subscribe-and-capture wiring.
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

    // MARK: - AC2: an unknown experience key returns nil

    /// `selectVariation(forKey:)` for a key absent from the config returns nil (the
    /// `fullExperience(forKey:)` miss short-circuits before any gate or bucket).
    @Test("AC2 — an unknown experience key returns nil")
    func unknownExperienceKeyReturnsNil() async throws {
        let config = try ProjectConfigFixtures.singleExperienceConfig(key: "known")
        let subject = makeExperienceManager()

        let variation = await select(subject, key: "no-such", in: config)

        #expect(variation == nil)
    }

    // MARK: - AC3: a sticky decision short-circuits (no bucket, no enqueue, no fire)

    /// A pre-seeded sticky decision for the visitor restores its variation directly: the result is the
    /// sticky variation, NO new bucketing event is enqueued (the bucket path is skipped), and the
    /// `.bucketing` EventBus subscriber does NOT fire (a sticky hit is not a NEW decision).
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

    // MARK: - AC2: an empty-audience experience runs (empty audience set = unrestricted)

    /// THE parity-critical case: an experience with NO audiences (empty `audiences` list) is
    /// UNRESTRICTED — the audience gate is bypassed, so a 100%-traffic experience buckets and returns
    /// a variation for ARBITRARY attributes (it is NOT rejected for "no matching audience").
    @Test("AC2 — an empty-audience experience runs (empty audience set is unrestricted, not rejected)")
    func emptyAudienceExperienceRuns() async throws {
        let config = try ProjectConfigFixtures.singleExperienceConfig(key: "open-exp")
        let subject = makeExperienceManager()

        let variation = await select(
            subject, key: "open-exp", in: config, attributes: ["anything": "goes"]
        )

        #expect(variation?.id == "var-1", "an empty-audience experience must bucket, not be rejected")
    }

    // MARK: - AC2: an audience-gate failure returns nil and enqueues nothing

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

    // MARK: - AC2: an audience-gate pass buckets

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

    // MARK: - AC8: enableTracking == false returns a variation but enqueues NOTHING

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

    // MARK: - AC8: enableTracking == true enqueues exactly one bucketing event

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

    // MARK: - AC9: a NEW decision fires the `.bucketing` system event with the right payload

    /// A NEW decision (100%-traffic no-audience experience, `enableTracking: true`) fires the
    /// `.bucketing` EventBus event EXACTLY ONCE, carrying the resolved experienceId, variationId, and
    /// visitorId. The async delivery is drained via the `MainActor` barrier before the capture is read.
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
}
