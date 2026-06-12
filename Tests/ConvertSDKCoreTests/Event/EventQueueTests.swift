// Tests/ConvertSDKCoreTests/Event/EventQueueTests.swift
// `@testable` import: the suite reaches the in-module `EventQueue` actor (Story 5.1) and
// observes its `apiQueueReleased` firing through the public `EventBus` (`on(.apiQueueReleased)`),
// never via the `package fire`. The `EventQueue` actor does not exist yet, so this suite is
// EXPECTED to fail to compile until the GREEN phase lands it (RED) — the ONLY unresolved symbol
// must be `EventQueue`; the mocks and helpers here compile against the real ports.
import Foundation
import Testing
@testable import ConvertSDKCore

/// RED-phase contract for the `EventQueue` actor (Epic 5 / Story 1 — batching + foreground
/// delivery, FR43 / NFR21 + AC1–AC9).
///
/// CONTRACT under test (the GREEN-phase implementer MUST satisfy these):
/// - `public actor EventQueue` at `Sources/ConvertSDKCore/Event/EventQueue.swift`, conforming
///   to ``EventSink`` (so `enqueue(_:for:segments:)` is its inward port).
/// - Initializer (LOCKED for the impl phase):
///     ```
///     EventQueue(
///         accountId: String,
///         projectId: String,
///         batchSize: Int = Defaults.batchSize,
///         releaseIntervalMs: Int = Defaults.releaseIntervalMs,
///         uploader: any EventUploader,
///         eventBus: EventBus,
///         trackingEnabled: Bool = true,
///         clock: any Clock = SystemClock()
///     )
///     ```
/// - `drain() -> [TrackingEvent]` — assembles the buffered entries into the canonical
///   `visitors:[{visitorId, segments, events}]` envelope (grouped by visitorId, first-seen
///   order; `nil` segments → `[:]`) and empties the buffer in ONE actor step. A second
///   `drain()` returns `[]` (AC1).
/// - On `upload(_:)` throwing, the drained entries are re-buffered in memory so a later
///   `drain()` returns them (AC1 re-enqueue-on-failure).
/// - Size trigger (AC3): the `batchSize`-th enqueue flushes exactly once, carrying `batchSize`
///   events; below threshold, zero uploads.
/// - Interval trigger (AC4): a timer loop sleeps `releaseIntervalMs` via the injected ``Clock``
///   and, on resume, delivers the buffered (below-threshold) batch — proven deterministically
///   with ``MockClock`` (no wall-clock wait, NFR21).
/// - On a successful flush, fires `SystemEvent.apiQueueReleased` with `eventCount` == delivered
///   count (AC8).
/// - With `trackingEnabled: false`, every enqueue is dropped: zero uploads, empty drain (AC9).
@Suite("EventQueue")
struct EventQueueTests {
    // MARK: Shared fixtures & helpers (SonarQube 3% new-duplicated-lines gate)

    /// The mocks + subject a scenario drives, returned as a named struct (not a tuple) so call
    /// sites read fields by name and the `large_tuple` lint rule stays satisfied. Mirrors the
    /// `ManagerHarness` shape in `MockCorePorts.swift`.
    struct QueueHarness {
        let queue: EventQueue
        let uploader: MockEventUploader
        let bus: EventBus
        let clock: MockClock
    }

    /// Builds the subject through ONE factory so no test re-spells the `EventQueue(...)`
    /// construction inline (SonarQube CPD is token-based — the duplicated block, not the
    /// argument names, is what trips the 3% gate). Every default mirrors the production default
    /// (`Defaults.batchSize` / `Defaults.releaseIntervalMs`, tracking on); a test overrides only
    /// the knob it exercises. The `uploader`/`bus`/`clock` it wires are returned in the harness so
    /// the test can assert on them without reconstructing the same instances.
    private func makeHarness(
        accountId: String = "acc1",
        projectId: String = "proj1",
        batchSize: Int = Defaults.batchSize,
        releaseIntervalMs: Int = Defaults.releaseIntervalMs,
        trackingEnabled: Bool = true,
        uploaderShouldFail: Bool = false
    ) -> QueueHarness {
        let uploader = MockEventUploader(shouldFail: uploaderShouldFail)
        let bus = EventBus()
        let clock = MockClock()
        let queue = EventQueue(
            accountId: accountId,
            projectId: projectId,
            batchSize: batchSize,
            releaseIntervalMs: releaseIntervalMs,
            uploader: uploader,
            eventBus: bus,
            trackingEnabled: trackingEnabled,
            clock: clock
        )
        return QueueHarness(queue: queue, uploader: uploader, bus: bus, clock: clock)
    }

    /// One bucketing entry; ids default so a test that only needs "some bucketing entry" passes
    /// no arguments, while grouping/identity tests vary them. Single owner of the
    /// `.bucketing(BucketingEventData(...))` construction so no test re-inlines it.
    static func makeBucketingEntry(
        experienceId: String = "exp1",
        variationId: String = "var1"
    ) -> TrackingEventEntry {
        .bucketing(BucketingEventData(experienceId: experienceId, variationId: variationId))
    }

    /// One conversion entry; `goalId` defaults. Single owner of the `.conversion(...)`
    /// construction so no test re-inlines it.
    static func makeConversionEntry(goalId: String = "goal1") -> TrackingEventEntry {
        .conversion(ConversionEventData(goalId: goalId))
    }

    /// Enqueues `count` bucketing entries for `visitorId` (segments `nil`) so the size-trigger
    /// and disabled-tracking tests express "N enqueues" in one call instead of a copied loop.
    /// `nil` segments exercise the AC5 `segments: {}` default the envelope must apply.
    private func enqueueBucketing(
        _ count: Int,
        for visitorId: String,
        on queue: EventQueue
    ) async {
        for _ in 0..<count {
            await queue.enqueue(Self.makeBucketingEntry(), for: visitorId, segments: nil)
        }
    }

    /// Lets already-dispatched `MainActor` callbacks run before a `confirmation` body exits.
    ///
    /// `EventBus.fire` delivers each `.apiQueueReleased` callback as a `Task { @MainActor in … }`,
    /// so the drain must await the `MainActor`'s serial executor — not the cooperative pool.
    /// `await MainActor.run { }` enqueues a barrier job behind the already-hopped callback jobs;
    /// because the `MainActor` executor is serial/FIFO, the barrier completes only after every
    /// prior callback has run. `Task.yield()` does NOT suffice — it yields the cooperative thread
    /// and never awaits the separate `MainActor` executor. Pure executor barrier, no wall-clock
    /// wait (NFR21). Mirrors `EventBusTests.drain()` / `ConfigStoreTests.drain()`.
    private func drainMainActor() async {
        await MainActor.run { }
    }

    /// Waits for the queue's UNSTRUCTURED flush `Task` to finish its async `upload(_:)` by
    /// yielding the cooperative thread until the uploader has recorded `count` calls (or a
    /// bounded budget is spent). The size-trigger flush runs on a detached/child task the
    /// `enqueue` call does not await, so a plain post-enqueue read can observe zero uploads
    /// purely because that task has not been scheduled yet. This is a SCHEDULING barrier, NOT a
    /// timing assertion: it asserts no elapsed-duration threshold (NFR21) — it only re-checks an
    /// EVENTUAL count across a finite number of yields, then returns whatever the count reached
    /// (the caller's `#expect` makes the real assertion). The budget (200 yields) is a deadlock
    /// guard, not a deadline.
    private func awaitUploadCount(_ uploader: MockEventUploader, reaches count: Int) async {
        for _ in 0..<200 {
            if await uploader.callCount >= count { return }
            await Task.yield()
        }
    }

    /// Polls `recorder` until the `apiQueueReleased` callback has recorded a count, DRAINING the
    /// MainActor on every iteration so the callback's `Task { @MainActor in … }` job actually runs
    /// before each check (the fire hops to the MainActor executor, so a cooperative `Task.yield()`
    /// alone would never advance it). Returns the recorded count, or `nil` if the bounded budget is
    /// spent (a deadlock guard, not a deadline — NFR21: no elapsed-duration threshold is asserted).
    private func awaitReleasedCount(_ recorder: ReleasedCountRecorder) async -> Int? {
        for _ in 0..<200 {
            if let count = await recorder.recorded { return count }
            await drainMainActor()
            await Task.yield()
        }
        return await recorder.recorded
    }

    // MARK: Scenario 1 — drain assembles the envelope and empties the buffer atomically (AC1)

    @Test("drain returns the buffered batch once, then empties (a second drain is empty)")
    func drainIsAtomicAndEmptiesBuffer() async {
        let harness = makeHarness()
        await harness.queue.enqueue(Self.makeBucketingEntry(), for: "v1", segments: nil)
        await harness.queue.enqueue(Self.makeConversionEntry(), for: "v1", segments: nil)

        let first = await harness.queue.drain()
        let second = await harness.queue.drain()

        // One TrackingEvent envelope carrying both entries; the buffer is empty afterwards.
        #expect(first.count == 1)
        #expect(first.first?.visitors.first?.events.count == 2)
        #expect(second.isEmpty)
    }

    // MARK: Scenario 2 — a failed upload re-buffers the drained entries (AC1 re-enqueue)

    @Test("entries drained for a failed upload are re-buffered and returned by a later drain")
    func failedUploadReEnqueuesEntries() async {
        // batchSize 1 makes the lone enqueue trip the size flush; the uploader throws, so the
        // flushed entry must return to the buffer rather than vanish.
        let harness = makeHarness(batchSize: 1, uploaderShouldFail: true)
        await harness.queue.enqueue(Self.makeBucketingEntry(), for: "v1", segments: nil)
        await awaitUploadCount(harness.uploader, reaches: 1)

        // The upload was attempted (and threw); the entry is back in the buffer for re-delivery.
        #expect(await harness.uploader.callCount == 1)
        let recovered = await harness.queue.drain()
        #expect(recovered.first?.visitors.first?.events.count == 1)
    }

    // MARK: Scenario 3 — entries group into per-visitor envelopes in first-seen order (FR43/AC5)

    @Test("drain groups entries into one event with per-visitor visitors[] in first-seen order")
    func drainGroupsEntriesByVisitorFirstSeen() async {
        let harness = makeHarness()
        // v1 gets two entries, then v2 gets one — first-seen order is v1, then v2.
        await harness.queue.enqueue(Self.makeBucketingEntry(), for: "v1", segments: nil)
        await harness.queue.enqueue(Self.makeConversionEntry(), for: "v1", segments: nil)
        await harness.queue.enqueue(Self.makeBucketingEntry(), for: "v2", segments: nil)

        let batch = await harness.queue.drain()
        let visitors = batch.first?.visitors

        #expect(batch.count == 1)
        #expect(visitors?.count == 2)
        #expect(visitors?.first?.visitorId == "v1")
        #expect(visitors?.first?.events.count == 2)
        #expect(visitors?.last?.visitorId == "v2")
        #expect(visitors?.last?.events.count == 1)
        // nil segments → the canonical empty map (AC5 "segments": {}).
        #expect(visitors?.first?.segments.isEmpty == true)
    }

    // MARK: Scenario 4 — only the canonical eventType strings appear in a drained envelope (AC2)

    @Test("a drained envelope tags entries with only the bucketing/conversion eventType strings")
    func drainedEntriesUseCanonicalEventTypeStrings() async {
        let harness = makeHarness()
        await harness.queue.enqueue(Self.makeBucketingEntry(), for: "v1", segments: nil)
        await harness.queue.enqueue(Self.makeConversionEntry(), for: "v1", segments: nil)

        let events = await harness.queue.drain().first?.visitors.first?.events ?? []
        let eventTypes = Set(events.map(\.eventType))
        #expect(eventTypes == ["bucketing", "conversion"])
    }

    // MARK: Scenario 5 — the size trigger flushes exactly at batchSize, not before (AC3)

    /// AC3 size trigger, both sides folded into ONE test over a single 10-enqueue sequence so the
    /// "below threshold = 0 uploads" and "AT threshold = 1 upload of `batchSize`" invariants stay
    /// adjacent and share the enqueue loop (avoiding a CPD duplicate of two near-identical 9-vs-10
    /// setups). The unstructured flush `Task` is awaited via the scheduling barrier, never a
    /// wall-clock sleep (NFR21).
    @Test("enqueueing batchSize-1 triggers no upload; the batchSize-th flushes exactly one batch")
    func sizeTriggerFlushesExactlyAtThreshold() async {
        let harness = makeHarness(batchSize: Defaults.batchSize)
        await enqueueBucketing(Defaults.batchSize - 1, for: "v1", on: harness.queue)
        // Below threshold: NO flush Task is ever launched (the size trigger fires only AT batchSize),
        // so assert the zero count DIRECTLY — a `awaitUploadCount` barrier here would be a negative
        // check that just burns its yield budget and could mask a slow-but-real flush on loaded CI.
        #expect(await harness.uploader.callCount == 0)

        // The batchSize-th enqueue trips the flush: exactly one upload carrying batchSize events.
        await harness.queue.enqueue(Self.makeBucketingEntry(), for: "v1", segments: nil)
        await awaitUploadCount(harness.uploader, reaches: 1)
        #expect(await harness.uploader.callCount == 1)
        let uploaded = await harness.uploader.uploadedBatches().first ?? []
        #expect(uploaded.first?.visitors.first?.events.count == Defaults.batchSize)
    }

    // MARK: Scenario 6 — the interval timer delivers a below-threshold batch deterministically (AC4)

    /// AC4 interval trigger, parameterized over two intervals (`@Test(arguments:)`) so the timer
    /// behavior is proven for more than one configured value WITHOUT a copied second test body —
    /// the `MockClock` makes each release fire on `fireNext()` with NO wall-clock time (NFR21).
    /// The buffer holds ONE below-threshold entry, so only the timer (never the size trigger) can
    /// deliver it; after the single release fires, the buffer is empty and the uploader carries
    /// exactly that one-event batch. The asserted interval (`requestedSleeps()`) proves the loop
    /// slept for the configured value, not a hardcoded one.
    @Test(
        "the interval timer delivers a below-threshold buffer on the configured release tick",
        arguments: [250, 1_000]
    )
    func intervalTimerDeliversBelowThresholdBatch(intervalMs: Int) async {
        let harness = makeHarness(batchSize: Defaults.batchSize, releaseIntervalMs: intervalMs)
        await harness.queue.enqueue(Self.makeBucketingEntry(), for: "v1", segments: nil)

        // Release exactly one timer tick: the parked (or pre-armed) sleep returns, the loop drains
        // the single entry and uploads it. Deterministic — fireNext is the clock, not the wall.
        await harness.clock.fireNext()
        await awaitUploadCount(harness.uploader, reaches: 1)

        #expect(await harness.uploader.callCount == 1)
        let uploaded = await harness.uploader.uploadedBatches().first ?? []
        #expect(uploaded.first?.visitors.first?.events.count == 1)
        // The buffer was delivered, not duplicated: a follow-up drain is empty.
        #expect(await harness.queue.drain().isEmpty)
        // The loop slept on the CONFIGURED interval before the release fired.
        #expect(await harness.clock.requestedSleeps().contains(intervalMs))
    }

    // MARK: Scenario 7 — a successful flush fires apiQueueReleased with the delivered count (AC8)

    @Test("a successful flush fires apiQueueReleased carrying the delivered event count")
    func successfulFlushFiresApiQueueReleased() async {
        let harness = makeHarness(batchSize: Defaults.batchSize)
        // An actor-isolated sink the callback writes the delivered count into. Polling THIS (rather
        // than `uploader.callCount`) closes a race: `flush` fires `apiQueueReleased` only AFTER its
        // `await uploader.upload(...)` returns, and `EventBus.fire` then dispatches the callback as a
        // separate `Task { @MainActor in … }`. So the upload completing does NOT mean the callback has
        // run — waiting on the upload count and draining the MainActor once can exit before the fire is
        // even enqueued. `awaitReleasedCount` drains the MainActor on every poll, so the callback's
        // MainActor job is guaranteed to have run once the recorded count appears. No wall-clock wait.
        let recorder = ReleasedCountRecorder()
        _ = await harness.bus.on(.apiQueueReleased) { payload in
            let count = Self.releasedCount(of: payload)
            Task { await recorder.record(count) }
        }
        await enqueueBucketing(Defaults.batchSize, for: "v1", on: harness.queue)
        let delivered = await awaitReleasedCount(recorder)
        // Fired exactly once, carrying the delivered event count (== batchSize for one full batch).
        #expect(delivered == Defaults.batchSize)
    }

    // MARK: Scenario 8 — tracking disabled drops every entry: no upload, empty drain (AC9)

    @Test("with tracking disabled, enqueues are dropped: zero uploads and an empty drain")
    func trackingDisabledDropsEntries() async {
        let harness = makeHarness(batchSize: Defaults.batchSize, trackingEnabled: false)
        await enqueueBucketing(Defaults.batchSize, for: "v1", on: harness.queue)
        // A disabled queue drops every entry at the `enqueue` guard — it never buffers and never
        // launches a flush Task — so assert the zero count DIRECTLY (a `awaitUploadCount` barrier
        // would be a negative check burning its yield budget for an upload that can never happen).
        #expect(await harness.uploader.callCount == 0)
        #expect(await harness.queue.drain().isEmpty)
    }

    /// Unwraps the `eventCount` carried by an `.apiQueueReleased` payload; `nil` for any other
    /// case. Keeps the `switch` out of the test body and gives the AC8 assertion one field to
    /// compare — mirrors `EventBusTests.experienceId(of:)` / `ConfigStoreTests.snapshotAccountId(of:)`.
    private static func releasedCount(of payload: EventPayloadValue) -> Int? {
        guard case let .apiQueueReleased(released) = payload else { return nil }
        return released.eventCount
    }
}

/// Actor sink the `apiQueueReleased` callback records the delivered event count into, so the AC8
/// test can poll for the fire deterministically (the callback runs on a `MainActor` hop off the
/// `EventBus.fire`, not synchronously). An `actor` satisfies the `Sendable` capture the `@Sendable`
/// bus callback requires with no suppression; `recorded` is `nil` until the first fire lands.
private actor ReleasedCountRecorder {
    private(set) var recorded: Int?

    /// Stores the first delivered count; ignores any subsequent fire so a double-delivery would be
    /// caught by the count check rather than silently overwritten.
    func record(_ count: Int?) {
        guard recorded == nil else { return }
        recorded = count
    }
}
