// Tests/ConvertSwiftSDKCoreTests/Event/EventQueueTests.swift
// `@testable` import: the suite reaches the in-module `EventQueue` actor and observes its
// `apiQueueReleased` firing through the public `EventBus` (`on(.apiQueueReleased)`), never via the
// `package fire`.
//
// RED state: the eight Story-5.1 scenarios are FROZEN (committed green). This file is now extended
// for Story 5.2 (on-disk persistence + exactly-once), so it is EXPECTED to fail to compile until the
// GREEN phase evolves `EventQueue` — the ONLY errors must stem from the not-yet-added 5.2 production
// API: the non-defaulted `store:` init param, the now-`async` `drain()`, and the new `start()`. The
// mocks and helpers here (including `MockEventQueueStore`) compile against the already-updated ports.
//
// `file_length` is disabled file-wide and `type_body_length` is disabled around the `EventQueueTests`
// struct below (both named rules — never a blanket disable-of-all; the type_body_length disable is
// paired with a matching enable directive right after the struct): this is ONE cohesive
// `@Suite("EventQueue")` whose tests all share the `makeHarness` factory and the static entry/envelope
// helpers, so splitting it across files to shave lines would fragment the suite for no readability gain
// (and would force the private helpers to be duplicated — a SonarQube CPD risk). The file crossed the
// 400-line `file_length` default with the Story-5.2 disk scenarios; the struct body crossed the 250-line
// `type_body_length` default with the Story-5.3 cross-path exactly-once scenarios (F-052: Scenario 15
// drain-guard / Scenario 16 cold-start-guard). Mirrors the file-wide `file_length` disable convention in
// `MockCorePorts.swift` / `Tests/ConvertSwiftSDKTests/Support/TestFixtures.swift`.
// swiftlint:disable file_length
import Foundation
import Testing
@testable import ConvertSwiftSDKCore

// swiftlint:disable type_body_length

/// Contract for the `EventQueue` actor (Epic 5 / Story 1 — batching + foreground delivery,
/// FR43 / NFR21 + AC1–AC9), EVOLVED by Story 5.2 (on-disk persistence & exactly-once). The
/// Scenario 1–8 cases below are the FROZEN 5.1 behavioral contract (their observable assertions
/// are unchanged); Scenario 9–12 add the 5.2 disk behaviors. Where 5.2 changed the MECHANISM the
/// notes below say so — the 5.1 assertions still hold because the new disk-first `drain()` re-
/// delivers what the old in-memory re-buffer used to.
///
/// CONTRACT under test:
/// - `public actor EventQueue` at `Sources/ConvertSwiftSDKCore/Event/EventQueue.swift`, conforming
///   to ``EventSink`` (so `enqueue(_:for:segments:)` is its inward port).
/// - Initializer (Story 5.2 added the NON-defaulted `store:` param; the 5.1 params are unchanged):
///     ```
///     EventQueue(
///         accountId: String,
///         projectId: String,
///         batchSize: Int = Defaults.batchSize,
///         releaseIntervalMs: Int = Defaults.releaseIntervalMs,
///         uploader: any EventUploader,
///         eventBus: EventBus,
///         trackingEnabled: Bool = true,
///         clock: any Clock = SystemClock(),
///         store: any EventQueueStore        // 5.2 — production injects; tests default it in makeHarness
///     )
///     ```
/// - `drain() async -> [TrackingEvent]` (5.2 made it `async`) — loads the on-disk queue FIRST,
///   then assembles the buffered entries into the canonical `visitors:[{visitorId, segments,
///   events}]` envelope (grouped by visitorId, first-seen order; `nil` segments → `[:]`), merges
///   DISK-FIRST, and clears BOTH the buffer and the on-disk file in ONE actor step. A second
///   `drain()` returns `[]` (AC1/AC3).
/// - On `upload(_:)` throwing, the drained batch is re-PERSISTED TO DISK (5.2 — was an in-memory
///   re-buffer in 5.1) so a later disk-first `drain()` re-delivers it (AC1 durable fallback).
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
        let store: MockEventQueueStore
    }

    /// Builds the subject through ONE factory so no test re-spells the `EventQueue(...)`
    /// construction inline (SonarQube CPD is token-based — the duplicated block, not the
    /// argument names, is what trips the 3% gate). Every default mirrors the production default
    /// (`Defaults.batchSize` / `Defaults.releaseIntervalMs`, tracking on); a test overrides only
    /// the knob it exercises. The `uploader`/`bus`/`clock`/`store` it wires are returned in the
    /// harness so the test can assert on them without reconstructing the same instances.
    ///
    /// `store` defaults to a fresh empty ``MockEventQueueStore`` so the eight Story-5.1 tests pass
    /// no argument and keep working unchanged; a Story-5.2 disk-persistence test injects (or, since
    /// `seed` is actor-isolated, post-seeds) its own store to stage the on-disk fixture.
    private func makeHarness(
        accountId: String = "acc1",
        projectId: String = "proj1",
        batchSize: Int = Defaults.batchSize,
        releaseIntervalMs: Int = Defaults.releaseIntervalMs,
        trackingEnabled: Bool = true,
        uploaderShouldFail: Bool = false,
        store: MockEventQueueStore = MockEventQueueStore()
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
            clock: clock,
            store: store
        )
        return QueueHarness(queue: queue, uploader: uploader, bus: bus, clock: clock, store: store)
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

    /// One persisted ``TrackingEvent`` envelope carrying a single bucketing event for `visitorId`,
    /// shaped the way a prior process would have left it in the queue file. Single owner of the
    /// seed-envelope construction so the Story-5.2 disk-first / cold-start tests stage their fixture
    /// in one call (`accountId`/`projectId` mirror `makeHarness`'s defaults so a loaded envelope is
    /// indistinguishable from one the queue itself would assemble).
    static func makeStoredEvent(visitorId: String) -> TrackingEvent {
        TrackingEvent(
            accountId: "acc1",
            projectId: "proj1",
            visitors: [Visitor(visitorId: visitorId, segments: [:], events: [makeBucketingEntry()])]
        )
    }

    /// Flattens a delivered/drained `[TrackingEvent]` to the visitorIds it carries, in envelope-then-
    /// visitor order. Single owner of the `flatMap(\.visitors).map(\.visitorId)` chain so the
    /// disk-first-ordering (AC3) and exactly-once (AC9) assertions express intent, not the traversal.
    static func visitorIds(of batch: [TrackingEvent]) -> [String] {
        batch.flatMap(\.visitors).map(\.visitorId)
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

    /// Generic sibling of ``awaitUploadCount(_:reaches:)`` for the Story-5.2 disk-side counters: yields
    /// the cooperative thread until the awaited `actual` count reaches `count` (or the 200-yield budget
    /// is spent). The failed-flush persist (AC1) and the failure-then-success cycle (AC9) complete on
    /// the same UNSTRUCTURED flush `Task` the enqueue does not await, and the `store.persist(...)` /
    /// `store.clear()` runs AFTER `uploader.upload(...)` returns/throws — so waiting on the upload count
    /// alone can exit before the disk side effect lands. Polling a caller-supplied async getter (rather
    /// than a second `MockEventUploader`-typed copy of this loop) keeps it reusable across the store's
    /// distinct counters with no CPD-duplicate barrier. Same contract as the upload barrier: a
    /// SCHEDULING guard over an EVENTUAL count, never an elapsed-duration threshold (NFR21); the
    /// caller's `#expect` makes the real assertion.
    private func awaitCount(reaches count: Int, _ actual: @Sendable () async -> Int) async {
        for _ in 0..<200 {
            if await actual() >= count { return }
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

    // MARK: Scenario 2 — a failed upload persists the drained batch to disk for re-delivery (AC1)
    //
    // FROZEN 5.1 assertion, EVOLVED 5.2 mechanism: in 5.1 the drained entries were re-buffered in
    // memory; in 5.2 the failure path persists the assembled batch to the on-disk store and clears
    // the buffer, and the new disk-first `drain()` loads it back. The observable outcome the test
    // asserts (a later `drain()` returns the failed entry) is identical — only the mechanism moved
    // from memory to disk. The `MockEventQueueStore` defaulted into `makeHarness` is the disk.

    @Test("an entry whose upload failed is persisted to disk and returned by a later drain")
    func failedUploadReEnqueuesEntries() async {
        // batchSize 1 makes the lone enqueue trip the size flush; the uploader throws, so the
        // flushed entry must survive (persisted to the store) rather than vanish.
        let harness = makeHarness(batchSize: 1, uploaderShouldFail: true)
        await harness.queue.enqueue(Self.makeBucketingEntry(), for: "v1", segments: nil)
        await awaitUploadCount(harness.uploader, reaches: 1)

        // The upload was attempted (and threw); the entry is now on disk, so the disk-first
        // `drain()` below re-delivers it (5.2 durable fallback).
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
        // The first (and only) fire carried the delivered event count (== batchSize for one full batch).
        #expect(delivered == Defaults.batchSize)
        // AC8 "fires ONCE per flush": settle the MainActor a few more times to give any spurious second
        // fire a chance to land, then assert exactly one delivery — a count check alone would not catch
        // a duplicate fire that happened to carry the same count.
        for _ in 0..<5 { await drainMainActor() }
        #expect(await recorder.fireCount == 1)
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

    // MARK: Scenario 9 — a failed flush persists the batch to DISK, not back into memory (AC1, 5.2)

    /// Story-5.2 evolution of the AC1 failure path: where 5.1 re-buffered the drained entries in
    /// memory (`buffer = drained + buffer`), the on-disk story instead persists the assembled batch
    /// through ``EventQueueStore/persist(_:)`` and empties the buffer — so a process death after the
    /// failed upload still has the batch durably on disk for the next cold start. `batchSize 1` trips
    /// the flush on the lone enqueue; the uploader throws, so the catch path must hit `persist`.
    @Test("a failed flush persists the assembled batch to disk and clears the in-memory buffer")
    func failedFlushPersistsToDisk() async {
        let harness = makeHarness(batchSize: 1, uploaderShouldFail: true)
        await harness.queue.enqueue(Self.makeBucketingEntry(), for: "v1", segments: nil)
        // The upload is ATTEMPTED (and throws); persist runs AFTER it on the same flush Task, so wait
        // for the upload then for the disk write to land (NFR21: scheduling barriers, no wall clock).
        await awaitUploadCount(harness.uploader, reaches: 1)
        await awaitCount(reaches: 1) { await harness.store.persistCallCount }

        #expect(await harness.store.persistCallCount >= 1)
        // The assembled batch (one visitor, one event) is now on disk — not silently dropped.
        let onDisk = await harness.store.storedEvents
        #expect(onDisk.isEmpty == false)
        #expect(Self.visitorIds(of: onDisk) == ["v1"])
    }

    // MARK: Scenario 10 — drain merges disk-first then memory and clears BOTH (AC3, 5.2)

    /// AC3 disk-first merge: a `drain()` loads the persisted queue as its FIRST await, prepends those
    /// `diskEvents` to `assemble(buffer)` (disk-first), then clears the buffer AND the store in the
    /// same actor step. Two seeded disk envelopes (`disk-v1`, `disk-v2`) plus one in-memory entry
    /// (`memory-v3`) must come back in disk-then-memory order, and a follow-up `drain()` is empty
    /// (both surfaces were cleared). Seeding is post-construction because `seed` is actor-isolated
    /// and `makeHarness` owns the store instance the queue was wired with.
    @Test("drain returns disk events before memory events and clears both surfaces")
    func drainMergesDiskFirstThenClearsBoth() async {
        let harness = makeHarness()
        await harness.store.seed([
            Self.makeStoredEvent(visitorId: "disk-v1"),
            Self.makeStoredEvent(visitorId: "disk-v2")
        ])
        await harness.queue.enqueue(Self.makeBucketingEntry(), for: "memory-v3", segments: nil)

        let drained = await harness.queue.drain()
        // Disk-first: the two persisted visitors precede the in-memory one, in seeded then enqueue order.
        #expect(Self.visitorIds(of: drained) == ["disk-v1", "disk-v2", "memory-v3"])
        // The store was cleared in the same actor step as the buffer…
        #expect(await harness.store.clearCallCount >= 1)
        // …so nothing remains: a second drain (empty disk + empty buffer) returns nothing.
        #expect(await harness.queue.drain().isEmpty)
    }

    // MARK: Scenario 11 — cold-start start() re-expands the persisted queue into the buffer (AC5, 5.2)

    /// AC5 cold-start recovery: `start()` loads the persisted queue and re-expands each loaded
    /// ``TrackingEvent``'s visitors/events back into buffered rows, so a subsequent `drain()` returns
    /// the recovered event — proving `start()` rehydrated the buffer from disk. Asserted via `drain()`
    /// (not auto-flush timing) so no wall clock is involved (NFR21). `loadCallCount` after `start()`
    /// confirms `start()` itself consulted the store (the re-expansion entry point), and `contains`
    /// (rather than an exact count) keeps the assertion robust to the implementer's choice of whether
    /// `start()` also clears disk — both variants deliver the recovered visitor through `drain()`.
    @Test("start() loads the persisted queue so a later drain returns the recovered event")
    func coldStartLoadsPersistedQueue() async {
        let harness = makeHarness()
        await harness.store.seed([Self.makeStoredEvent(visitorId: "persisted-1")])

        await harness.queue.start()
        #expect(await harness.store.loadCallCount >= 1)

        let drained = await harness.queue.drain()
        #expect(Self.visitorIds(of: drained).contains("persisted-1"))
    }

    // MARK: Scenario 12 — exactly-once across a crash (persist) → restart (success) cycle (AC9, 5.2)

    /// AC9 exactly-once: a failure-then-success cycle must deliver every event exactly once — no loss,
    /// no double-send — with the crash point simulated by the mock store's persist (NOT a real process
    /// kill). `batchSize 1`: enqueue A while the uploader fails, so A's flush persists A to disk (the
    /// "crashed before delivery" state). Flip the uploader to succeed, then enqueue B (a distinct
    /// visitor): its flush `drain()` now loads A from disk + B from memory and delivers BOTH in one
    /// upload. Exactly-once is asserted over the SUCCESSFULLY delivered batches only — the failed
    /// attempt is recorded by the mock too (it appends before throwing), so the successful deliveries
    /// are the attempts AFTER the captured failed-attempt count; flattening those to visitorIds must
    /// yield each original exactly once (Set count == array count), and a final `drain()` is empty
    /// (nothing stranded on disk or in memory).
    @Test("a failure-then-success cycle delivers every event exactly once with no loss or duplication")
    func exactlyOnceAcrossFailureThenSuccess() async {
        let harness = makeHarness(batchSize: 1, uploaderShouldFail: true)
        // Event A fails to upload and is persisted to disk (the simulated crash-before-delivery point).
        await harness.queue.enqueue(Self.makeBucketingEntry(experienceId: "expA"), for: "vA", segments: nil)
        await awaitUploadCount(harness.uploader, reaches: 1)
        await awaitCount(reaches: 1) { await harness.store.persistCallCount }
        let failedAttempts = await harness.uploader.callCount

        // Restart: the uploader now succeeds. Event B's flush loads A (disk) + B (memory) and ships both.
        await harness.uploader.setShouldFail(false)
        await harness.queue.enqueue(Self.makeBucketingEntry(experienceId: "expB"), for: "vB", segments: nil)
        await awaitUploadCount(harness.uploader, reaches: failedAttempts + 1)

        // Count only the SUCCESSFUL deliveries (the attempts after the failed ones): each original
        // visitorId must appear exactly once — no event lost, none delivered twice.
        let succeeded = await harness.uploader.uploadedBatches().dropFirst(failedAttempts)
        let deliveredIds = succeeded.flatMap { Self.visitorIds(of: $0) }
        #expect(Set(deliveredIds).count == deliveredIds.count)
        #expect(Set(deliveredIds) == ["vA", "vB"])
        // Nothing stranded: the disk-clearing successful drain leaves both surfaces empty.
        #expect(await harness.queue.drain().isEmpty)
    }

    // MARK: Scenario 13 — background transition persists the live buffer to disk (Story 5.3, lifecycle)

    /// Story-5.3 background-transition durability: `LifecycleObserver` calls `persistBeforeBackground()`
    /// when the app backgrounds, so the in-memory buffer is flushed to disk BEFORE the OS can suspend
    /// the process — closing the gap where a below-threshold buffer (never size/interval-flushed) would
    /// be lost on a cold kill. `batchSize 100` keeps the three enqueues below threshold so NO auto-flush
    /// races the explicit persist; the method assembles the buffer into the canonical envelope, hands it
    /// to ``EventQueueStore/persist(_:)`` ONCE, and empties the buffer. The three distinct visitors group
    /// into one envelope in first-seen order (`assemble`), so the persisted batch flattens to v1/v2/v3,
    /// and a follow-up `drain()` returns them DISK-FIRST (the buffer is now empty, the store holds them) —
    /// proving the in-memory buffer moved to disk rather than being duplicated across both surfaces.
    @Test("persistBeforeBackground moves the buffer to the store and clears the in-memory buffer")
    func persistBeforeBackgroundMovesBufferToDisk() async {
        let harness = makeHarness(batchSize: 100)
        await enqueueBucketing(1, for: "v1", on: harness.queue)
        await enqueueBucketing(1, for: "v2", on: harness.queue)
        await enqueueBucketing(1, for: "v3", on: harness.queue)

        await harness.queue.persistBeforeBackground()

        // Persisted exactly once, carrying all three visitors in first-seen order (one assembled envelope).
        #expect(await harness.store.persistCallCount == 1)
        #expect(Self.visitorIds(of: await harness.store.storedEvents) == ["v1", "v2", "v3"])
        // The buffer was emptied, so the recovery drain loads the three back disk-first (not duplicated).
        let drained = await harness.queue.drain()
        #expect(Self.visitorIds(of: drained) == ["v1", "v2", "v3"])
    }

    // MARK: Scenario 14 — background persist is a no-op when the buffer is empty (Story 5.3, lifecycle)

    /// The empty-buffer guard: a background transition with nothing buffered must NOT write an empty
    /// envelope to disk (which would needlessly bump the persist count and could overwrite a queue file
    /// the interval/size path is mid-flush of). `persistBeforeBackground` short-circuits on an empty
    /// buffer, so `persistCallCount` stays at zero.
    @Test("persistBeforeBackground is a no-op when the buffer is empty")
    func persistBeforeBackgroundIsNoOpWhenBufferEmpty() async {
        let harness = makeHarness()
        await harness.queue.persistBeforeBackground()
        #expect(await harness.store.persistCallCount == 0)
    }

    // MARK: Scenario 15 — drain declines while a background upload is in-flight (Story 5.3 / F-052)

    /// Cross-path exactly-once (F-052): while a durable background `URLSession` upload of the queue file
    /// is outstanding, `drain()` must NOT read or clear that file — nor drain the in-memory buffer — so a
    /// foreground-recovery flush that races the background upload does not re-deliver the same on-disk
    /// batch. The marker is staged via ``MockEventQueueStore/seedInFlight(_:)`` (a Core test has no real
    /// background session); with it set, `drain()` returns nothing, the seeded disk batch is left intact
    /// (`clearCallCount` stays 0), and the enqueued in-memory entry is retained. Once the marker clears
    /// (as the delegate's reconcile would), the next `drain()` delivers BOTH surfaces exactly once.
    @Test("drain declines to read or clear the queue file while a background upload is in-flight")
    func drainDeclinesWhileBackgroundUploadInFlight() async {
        let harness = makeHarness()
        await harness.store.seed([Self.makeStoredEvent(visitorId: "disk-v1")])
        await harness.store.seedInFlight(true)
        await harness.queue.enqueue(Self.makeBucketingEntry(), for: "memory-v2", segments: nil)

        // In-flight: drain delivers nothing and leaves the on-disk batch untouched for the background path.
        let blocked = await harness.queue.drain()
        #expect(blocked.isEmpty)
        #expect(await harness.store.clearCallCount == 0)
        #expect(Self.visitorIds(of: await harness.store.storedEvents) == ["disk-v1"])

        // The reconcile clears the marker; the next drain now delivers the retained disk + memory once.
        await harness.store.seedInFlight(false)
        let recovered = await harness.queue.drain()
        #expect(Self.visitorIds(of: recovered) == ["disk-v1", "memory-v2"])
    }

    // MARK: Scenario 16 — cold-start start() declines while a background upload is in-flight (F-052)

    /// Cross-path exactly-once (F-052) on the cold-start path: if a background upload of the queue file is
    /// outstanding from a prior process, `start()` must leave the file for the background session's
    /// reconcile rather than load + clear it (which would double-deliver against the in-flight upload).
    /// With the marker staged, `start()` does NOT consult `load()` and the seeded batch stays on disk;
    /// once the marker clears, a `drain()` recovers it exactly once. Contrast Scenario 11, where `start()`
    /// (no marker) loads the persisted queue.
    @Test("start() leaves the persisted queue for the background path while an upload is in-flight")
    func coldStartDeclinesWhileBackgroundUploadInFlight() async {
        let harness = makeHarness()
        await harness.store.seed([Self.makeStoredEvent(visitorId: "persisted-1")])
        await harness.store.seedInFlight(true)

        await harness.queue.start()

        // start() declined to load the file (it is owned by the background path) and left it on disk.
        #expect(await harness.store.loadCallCount == 0)
        #expect(await harness.store.clearCallCount == 0)
        #expect(Self.visitorIds(of: await harness.store.storedEvents) == ["persisted-1"])

        // After the reconcile clears the marker, the file is recovered exactly once.
        await harness.store.seedInFlight(false)
        #expect(Self.visitorIds(of: await harness.queue.drain()).contains("persisted-1"))
    }

    // MARK: Scenario 17 — setTrackingEnabled(false) drops subsequent enqueues (Story 5.6 AC1, runtime gate)

    /// Runtime tracking gate — CLOSE path: construct with `trackingEnabled: true` so the gate is
    /// open. Enqueue one entry and confirm it buffers (drain is non-empty). Then call
    /// `setTrackingEnabled(false)` to close the gate at runtime and enqueue a second entry; it must
    /// be dropped (no buffering, no upload). The already-buffered first entry is NOT purged (Story
    /// 5.6 AC notes "no queue purge on disable") — it is simply what remains in the buffer. No
    /// wall-clock wait (NFR21).
    @Test("setTrackingEnabled(false) drops subsequent enqueues without purging already-buffered entries")
    func runtimeDisableDropsSubsequentEnqueues() async {
        let harness = makeHarness()

        // Gate open: enqueue one entry — it buffers.
        await harness.queue.enqueue(Self.makeBucketingEntry(experienceId: "expA"), for: "vA", segments: nil)
        let countBeforeDisable = await harness.queue.drain().first?.visitors.first?.events.count ?? 0
        #expect(countBeforeDisable == 1, "open gate: first entry must buffer")

        // Close the runtime gate then enqueue a second entry.
        await harness.queue.setTrackingEnabled(false)
        await harness.queue.enqueue(Self.makeBucketingEntry(experienceId: "expB"), for: "vB", segments: nil)

        // The second entry was DROPPED — drain returns nothing (buffer was cleared by the prior drain;
        // expB was never buffered because the gate was closed).
        let drained = await harness.queue.drain()
        #expect(drained.isEmpty, "closed runtime gate: entry after setTrackingEnabled(false) must be dropped")
        // No upload was ever triggered (batchSize default is large; no flush Task launched).
        #expect(await harness.uploader.callCount == 0)
    }

    // MARK: Scenario 18 — setTrackingEnabled(true) re-opens the gate (Story 5.6 AC2)

    /// Runtime tracking gate — OPEN path: construct with `trackingEnabled: false` so the gate
    /// starts closed (every enqueue is dropped). Confirm the gate is closed, then call
    /// `setTrackingEnabled(true)` to re-open it at runtime. Enqueue a new entry; it must now buffer
    /// and appear in `drain()`. Proves the setter RE-OPENS the gate (not just a constructor knob).
    /// No wall-clock wait (NFR21).
    @Test("setTrackingEnabled(true) re-opens a closed gate so subsequent enqueues buffer and deliver")
    func runtimeEnableReopensGate() async {
        let harness = makeHarness(trackingEnabled: false)

        // Gate starts closed: an entry is dropped immediately.
        await harness.queue.enqueue(Self.makeBucketingEntry(experienceId: "expDropped"), for: "vDropped", segments: nil)
        #expect(await harness.queue.drain().isEmpty, "closed gate: entry before re-enable must be dropped")

        // Re-open the gate at runtime.
        await harness.queue.setTrackingEnabled(true)

        // Gate is now open: a new entry must buffer.
        await harness.queue.enqueue(Self.makeBucketingEntry(experienceId: "expKept"), for: "vKept", segments: nil)
        let drained = await harness.queue.drain()
        let visitorIds = Self.visitorIds(of: drained)
        #expect(visitorIds == ["vKept"], "re-opened gate: entry after setTrackingEnabled(true) must buffer and drain")
    }

    // MARK: Scenario 19 — no replay: dropped entries are never buffered, nothing to replay (Story 5.6 AC2)

    /// No-replay invariant at the `EventQueue` level: entries dropped during a closed window are
    /// never stored in the buffer, so `setTrackingEnabled(true)` cannot replay them — the gate
    /// re-opens the receive path, it does NOT flush a phantom buffer of dropped events. After
    /// re-enable, a `drain()` returns ONLY the post-reopen entry, not the dropped ones.
    ///
    /// Distinct from Scenario 18 in that it specifically verifies identity: the delivered batch
    /// contains ONLY the post-reopen visitor, confirming dropped entries left no residue.
    @Test("after setTrackingEnabled(true), drain has only post-reopen entries — dropped ones never buffered")
    func noReplayAfterRuntimeReEnable() async {
        let harness = makeHarness(trackingEnabled: false)

        // Drop two entries during the closed window.
        await harness.queue.enqueue(Self.makeBucketingEntry(experienceId: "expDrop1"), for: "vDrop1", segments: nil)
        await harness.queue.enqueue(Self.makeBucketingEntry(experienceId: "expDrop2"), for: "vDrop2", segments: nil)

        // Re-open the gate.
        await harness.queue.setTrackingEnabled(true)

        // Enqueue a single post-reopen entry.
        await harness.queue.enqueue(Self.makeBucketingEntry(experienceId: "expPost"), for: "vPost", segments: nil)

        // Drain must contain ONLY the post-reopen entry — the two dropped visitors must not appear.
        let drained = await harness.queue.drain()
        let deliveredIds = Self.visitorIds(of: drained)
        // Only the post-reopen visitor — no replay of dropped entries.
        #expect(deliveredIds == ["vPost"], "no replay: only post-reopen entry; dropped entries not buffered")
        // Exactly one entry in the batch (not three from a phantom replay).
        #expect(drained.first?.visitors.count == 1)
        // No upload was triggered (batchSize default; single post-reopen entry stays below threshold).
        #expect(await harness.uploader.callCount == 0)
    }

    /// Unwraps the `eventCount` carried by an `.apiQueueReleased` payload; `nil` for any other
    /// case. Keeps the `switch` out of the test body and gives the AC8 assertion one field to
    /// compare — mirrors `EventBusTests.experienceId(of:)` / `ConfigStoreTests.snapshotAccountId(of:)`.
    private static func releasedCount(of payload: EventPayloadValue) -> Int? {
        guard case let .apiQueueReleased(released) = payload else { return nil }
        return released.eventCount
    }
}
// swiftlint:enable type_body_length

/// Actor sink the `apiQueueReleased` callback records the delivered event count into, so the AC8
/// test can poll for the fire deterministically (the callback runs on a `MainActor` hop off the
/// `EventBus.fire`, not synchronously). An `actor` satisfies the `Sendable` capture the `@Sendable`
/// bus callback requires with no suppression; `recorded` is `nil` until the first fire lands.
private actor ReleasedCountRecorder {
    /// The count carried by the FIRST fire; `nil` until one lands.
    private(set) var recorded: Int?
    /// How many times the callback fired — so the AC8 test can assert "fires ONCE per flush", not
    /// merely that the first fire carried the right count (a spurious second fire would be caught).
    private(set) var fireCount = 0

    /// Records a delivery: bumps the fire count and stores the count of the FIRST fire (later fires
    /// bump the count but do not overwrite, so the test sees both "first count" and "how many fires").
    func record(_ count: Int?) {
        fireCount += 1
        if recorded == nil { recorded = count }
    }
}
