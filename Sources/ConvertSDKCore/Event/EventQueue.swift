// EventQueue.swift
// The foreground event-delivery queue (Epic 5 / Story 1 — batching + foreground delivery).
// Foundation-only — part of the pure-logic ConvertSDKCore target (no UIKit/AppKit/Security/
// BackgroundTasks): the actor batches produced entries and ships them through the injected
// `EventUploader`, driven by a size trigger and an interval timer gated on the injected `Clock`.

import Foundation

/// Batches produced tracking entries and delivers them to the Convert serving API.
///
/// The queue is the conforming ``EventSink`` (FR43 / NFR21 — AC1–AC9): the decisioning and
/// conversion paths enqueue single ``TrackingEventEntry`` values tagged with their visitor and
/// segments, and the queue assembles them into the canonical
/// `visitors:[{visitorId, segments, events}]` envelope grouped per visitor in first-seen order.
/// Two triggers release a batch:
///
/// - **Size** (AC3): once the buffer reaches `batchSize`, an unstructured flush ships the batch
///   so the enqueueing caller never blocks on the upload.
/// - **Interval** (AC4): a timer loop sleeps `releaseIntervalMs` via the injected ``Clock`` and,
///   on resume, flushes whatever is buffered — proven deterministically with a stepping clock so
///   no test waits on the wall clock (NFR21).
///
/// On a successful flush the queue fires ``SystemEvent/apiQueueReleased`` carrying the delivered
/// event count (AC8). On an upload failure the drained entries are restored to the buffer in their
/// original order so a later flush re-delivers them (AC1 re-enqueue-on-failure). With
/// `trackingEnabled: false` every enqueue is dropped (no buffering, no upload — AC9).
///
/// Concurrency shape: an `actor` — the buffer is actor-isolated shared mutable state, so concurrent
/// `enqueue`/`drain`/`flush` are race-free with NO lock and NO `@unchecked Sendable` (AR12).
public actor EventQueue: EventSink {
    /// One buffered entry retained with the identity needed to (re)assemble its envelope: the raw
    /// ``TrackingEventEntry`` plus its grouping `visitorId` and that visitor's `segments`. The
    /// buffer holds these — NOT assembled envelopes — so a failed upload can restore the exact
    /// entries and a later ``drain()`` re-groups them.
    private struct BufferedEntry {
        let entry: TrackingEventEntry
        let visitorId: String
        let segments: [String: String]
    }

    /// Convert account identifier stamped onto every assembled envelope.
    private let accountId: String
    /// Convert project identifier stamped onto every assembled envelope.
    private let projectId: String
    /// Buffered-entry count that trips the size flush (AC3). Stored so the trigger never hardcodes
    /// the literal — it defaults to ``Defaults/batchSize`` at construction.
    private let batchSize: Int
    /// Interval, in milliseconds, the timer loop sleeps between release attempts (AC4). Stored so
    /// the loop never hardcodes the literal — it defaults to ``Defaults/releaseIntervalMs``.
    private let releaseIntervalMs: Int
    /// The transport the assembled batch is shipped through (foreground or background adapter).
    private let uploader: any EventUploader
    /// The shared bus the queue fires ``SystemEvent/apiQueueReleased`` on after a successful flush.
    private let eventBus: EventBus
    /// When `false`, every enqueue is dropped: nothing buffers and nothing uploads (AC9 / FR6).
    private let trackingEnabled: Bool
    /// The injected time source the interval timer sleeps on (NFR21 determinism in tests).
    private let clock: any Clock
    /// The durable pending-event-queue persistence (Story 5.2 on-disk persistence + exactly-once).
    /// A failed flush persists its batch here, ``drain()`` loads it disk-first and clears it, and a
    /// cold-start ``start()`` re-expands it into the buffer — so events survive process death and are
    /// delivered exactly once. Production always injects the coordinated file-backed adapter; the
    /// pure-logic queue stays unaware of the file location or serialization (the adapter owns those).
    private let store: any EventQueueStore

    /// The pending entries awaiting delivery, in enqueue order. The sole shared mutable state.
    private var buffer: [BufferedEntry] = []
    /// The interval-timer loop, cancelled on ``deinit``. `nil` until the timer is armed on the FIRST
    /// enqueue (Swift 6 forbids touching this mutable actor-isolated property from the nonisolated
    /// `init`, so the loop is started lazily from the first actor-isolated `enqueue` instead).
    private var timerTask: Task<Void, Never>?

    /// Creates the queue and arms its interval timer.
    ///
    /// - Parameters:
    ///   - accountId: Account identifier stamped onto every assembled envelope.
    ///   - projectId: Project identifier stamped onto every assembled envelope.
    ///   - batchSize: Buffered-entry count that trips the size flush; defaults to ``Defaults/batchSize``.
    ///   - releaseIntervalMs: Milliseconds the timer sleeps between flushes; defaults to
    ///     ``Defaults/releaseIntervalMs``.
    ///   - uploader: The transport the assembled batch is shipped through.
    ///   - eventBus: The shared bus the queue fires ``SystemEvent/apiQueueReleased`` on.
    ///   - trackingEnabled: When `false`, every enqueue is dropped (AC9); defaults to `true`.
    ///   - clock: The injected time source the timer sleeps on; defaults to ``SystemClock``.
    ///   - store: The durable pending-event-queue persistence (Story 5.2). NON-defaulted —
    ///     production always injects the coordinated file-backed adapter so the on-disk fallback,
    ///     disk-first drain merge, and cold-start recovery are never silently skipped.
    public init(
        accountId: String,
        projectId: String,
        batchSize: Int = Defaults.batchSize,
        releaseIntervalMs: Int = Defaults.releaseIntervalMs,
        uploader: any EventUploader,
        eventBus: EventBus,
        trackingEnabled: Bool = true,
        clock: any Clock = SystemClock(),
        store: any EventQueueStore
    ) {
        self.accountId = accountId
        self.projectId = projectId
        self.batchSize = batchSize
        self.releaseIntervalMs = releaseIntervalMs
        self.uploader = uploader
        self.eventBus = eventBus
        self.trackingEnabled = trackingEnabled
        self.clock = clock
        self.store = store
        // The interval timer is armed lazily on the first `enqueue` (see `ensureTimerStarted`), not
        // here: Swift 6 forbids accessing the mutable actor-isolated `timerTask` from this nonisolated
        // initializer. Deferring to the first actor-isolated enqueue keeps the loop's start fully
        // actor-isolated with no `nonisolated(unsafe)` escape hatch.
    }

    /// Cancels the interval-timer loop when the queue is released.
    deinit {
        timerTask?.cancel()
    }

    // MARK: - EventSink

    /// Buffers one produced entry for eventual delivery, tagged with its visitor and segments.
    ///
    /// When tracking is disabled the entry is dropped immediately — nothing buffers and nothing
    /// uploads (AC9). `nil` segments are stored as the canonical empty map. When the buffer reaches
    /// ``batchSize`` an UNSTRUCTURED flush is launched so this call returns without awaiting the
    /// upload (AC3).
    ///
    /// - Parameters:
    ///   - event: The produced ``TrackingEventEntry`` (bucketing or conversion).
    ///   - visitorId: The visitor the entry belongs to — the key the envelope groups on.
    ///   - segments: The visitor's segments, or `nil` for the canonical empty map.
    public func enqueue(_ event: TrackingEventEntry, for visitorId: String, segments: [String: String]?) async {
        guard trackingEnabled else { return }
        // Arm the interval timer on the first real (tracking-enabled) enqueue. A disabled queue never
        // reaches here, so it never starts a timer (AC9).
        ensureTimerStarted()
        buffer.append(BufferedEntry(entry: event, visitorId: visitorId, segments: segments ?? [:]))
        if buffer.count >= batchSize {
            // Unstructured flush so the caller is not blocked on the upload (AC3). The child task
            // re-enters the actor for `flush()`, so the buffer mutation stays actor-isolated.
            Task { await self.flush() }
        }
    }

    /// Arms the interval-timer loop exactly once (idempotent). Called from the first tracking-enabled
    /// ``enqueue(_:for:segments:)`` — the loop sleeps ``releaseIntervalMs`` on the injected ``Clock``
    /// and flushes on each resume, until cancelled (AC4). `[weak self]` so the loop never keeps the
    /// queue alive; a deallocated queue ends the loop on its next iteration. Starting it here (rather
    /// than in the nonisolated `init`) keeps the mutable `timerTask` access fully actor-isolated.
    private func ensureTimerStarted() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runTimerTick()
            }
        }
    }

    // MARK: - Cold-start recovery

    /// Recovers any persisted queue at cold start: re-expands the on-disk envelopes back into the
    /// in-memory buffer, clears the disk, and arms the interval timer (AC5, Story 5.2).
    ///
    /// Each persisted ``TrackingEvent``'s `visitors[]`/`events[]` are flattened back into
    /// ``BufferedEntry`` rows so the existing ``assemble(_:)``/``flush()`` path handles them
    /// identically to freshly-enqueued entries. The disk is cleared AFTER loading into the buffer —
    /// the events now live ONLY in memory, so the first disk-first ``drain()`` will NOT re-load (and
    /// thus NOT double-deliver) them (exactly-once). The interval timer is armed so the recovered
    /// events are delivered by the next flush cycle even if NO new enqueue ever arrives (AC5).
    ///
    /// `store.load()`/`store.clear()` are wrapped in `try?`: a store error degrades to "nothing to
    /// recover" rather than throwing out of `start()`.
    public func start() async {
        let persisted = (try? await store.load()) ?? []
        // Re-expand each envelope's visitors[]/events back into BufferedEntry rows so the existing
        // assemble()/flush() path handles them identically to freshly-enqueued entries.
        for event in persisted {
            for visitor in event.visitors {
                for entry in visitor.events {
                    buffer.append(
                        BufferedEntry(entry: entry, visitorId: visitor.visitorId, segments: visitor.segments)
                    )
                }
            }
        }
        // Clear disk AFTER loading into the buffer: the events now live ONLY in memory, so the first
        // disk-first drain() will NOT re-load (and thus NOT double-deliver) them (exactly-once). Guarded
        // on non-empty so a clean first launch (nothing persisted) skips a needless clear.
        if !persisted.isEmpty {
            try? await store.clear()
        }
        // Arm the interval timer so recovered events are delivered even if NO new enqueue ever arrives
        // (AC5: the next flush cycle — size-trigger or interval-timer — naturally delivers them).
        ensureTimerStarted()
    }

    // MARK: - Background persistence

    /// Persists the in-memory buffer to the on-disk store and empties it, so the on-disk file is the
    /// authoritative record before the app is suspended (Story 5.3 / AC10 / FR36). Called by
    /// `LifecycleObserver` on a background transition, BEFORE the background upload task is enqueued
    /// from that same file. A no-op when the buffer is empty (a clean background with nothing pending
    /// leaves no `[]` file behind — `store.persist([])` would clear, but the guard skips the call
    /// entirely). `try?`: a store error degrades to "left in memory" rather than throwing out of the
    /// lifecycle hook, matching the no-throw store philosophy used by `flush()`/`drain()`.
    /// [Source: architecture.md#Durable Background Delivery — persist file on background]
    func persistBeforeBackground() async {
        guard !buffer.isEmpty else { return }
        try? await store.persist(assemble(buffer))
        buffer = []
    }

    // MARK: - Drain

    /// Merges the persisted (on-disk) queue with the in-memory buffer — DISK-FIRST — and clears BOTH
    /// surfaces in ONE actor step (AC1 / AC3, Story 5.2).
    ///
    /// The persisted queue is loaded as the FIRST `await`, so the on-disk snapshot is taken before
    /// anything is cleared. Actor isolation guarantees no other `drain()`/`enqueue()` runs to
    /// completion interleaved with this one; any `enqueue` that lands while `load()` is suspended is
    /// correctly captured by reading `buffer` AFTER the await (it joins this merge via `drainEntries`).
    /// The in-memory entries are then grouped per visitor in first-seen order (`nil` segments became
    /// the empty map at enqueue) and the disk is cleared, so the events live only in the returned
    /// value. Disk events precede memory events (oldest delivered first). A second call returns `[]` —
    /// the disk is now empty and the buffer cleared, so no entry is ever drained twice (exactly-once).
    ///
    /// `store.load()`/`store.clear()` are wrapped in `try?`: a store error degrades to an empty
    /// snapshot rather than throwing out of `drain()` (the adapter already returns `[]` on corruption;
    /// `clear` could in theory throw, which is swallowed so a partial drain never surfaces an error).
    ///
    /// - Returns: The disk-first merge of the persisted queue and the assembled buffer, or `[]` when
    ///   both surfaces are empty.
    public func drain() async -> [TrackingEvent] {
        // store.load() is the FIRST await: the on-disk snapshot is taken before any clear, and any
        // enqueue arriving while it is suspended is captured below by reading `buffer` AFTER the await.
        let diskEvents = (try? await store.load()) ?? []
        // drainEntries() reads+clears the buffer in one (sync) step AFTER the load await, then assemble
        // groups them into envelope(s); so an enqueue that landed during the load joins this merge.
        let inMemory = assemble(drainEntries())
        // Disk is now empty — the events live only in `inMemory` (re-delivered on a later drain if the
        // upload they feed fails). Swallowed so a clear error never throws out of a partial drain.
        try? await store.clear()
        // DISK-FIRST: the persisted (older) envelopes are delivered ahead of the freshly-buffered ones.
        return diskEvents + inMemory
    }

    // MARK: - Private

    /// Reads and clears the raw buffered entries in ONE actor step (no suspension between the read
    /// and the reset), so the entries can be re-buffered verbatim if their upload fails (AC1).
    private func drainEntries() -> [BufferedEntry] {
        let entries = buffer
        buffer = []
        return entries
    }

    /// Groups `entries` per visitor in first-seen order and wraps them in a single ``TrackingEvent``.
    ///
    /// The first time a `visitorId` is seen its position and `segments` are captured; subsequent
    /// entries for that visitor append to its event list without disturbing order. Returns `[]` for
    /// an empty input so a flush of nothing is a no-op. Shared by ``drain()`` and ``flush()`` so the
    ///
    /// SEGMENTS WIRE NOTE: every ``Visitor`` always carries a `segments` object — `{}` when no
    /// segments were provided (the `nil → [:]` resolution happens at enqueue). This is the canonical
    /// AC5 shape (`"segments": {}`, never absent), and INTENTIONALLY differs from the JS SDK's
    /// `api-manager.ts` `push`, which omits the field entirely when `segments` is falsy (`if (segments)
    /// visitor.segments = segments`). The iOS wire follows the spec's explicit empty-object form.
    /// assembly lives in one place.
    private func assemble(_ entries: [BufferedEntry]) -> [TrackingEvent] {
        guard !entries.isEmpty else { return [] }
        var order: [String] = []
        var eventsByVisitor: [String: [TrackingEventEntry]] = [:]
        var segmentsByVisitor: [String: [String: String]] = [:]
        for buffered in entries {
            if eventsByVisitor[buffered.visitorId] == nil {
                order.append(buffered.visitorId)
                segmentsByVisitor[buffered.visitorId] = buffered.segments
            }
            eventsByVisitor[buffered.visitorId, default: []].append(buffered.entry)
        }
        let visitors = order.map { visitorId in
            Visitor(
                visitorId: visitorId,
                segments: segmentsByVisitor[visitorId] ?? [:],
                events: eventsByVisitor[visitorId] ?? []
            )
        }
        return [TrackingEvent(accountId: accountId, projectId: projectId, visitors: visitors)]
    }

    /// Drains the DISK-FIRST merge (persisted queue + in-memory buffer) and ships it through the
    /// ``uploader`` — the exactly-once delivery path (AC1 / AC8 / AC9, Story 5.2).
    ///
    /// Delivery goes through ``drain()`` (not the bare buffer): `drain()` loads the persisted queue
    /// disk-first, merges it ahead of the assembled buffer, and clears BOTH surfaces in one actor step.
    /// So a restart's flush re-delivers any batch a prior failure persisted to disk TOGETHER with the
    /// freshly-buffered entries — the crash-persisted events are delivered by the natural flush cycle,
    /// exactly once (AC9), not stranded on disk until an explicit external drain.
    ///
    /// On success, fires ``SystemEvent/apiQueueReleased`` with the delivered event count (AC8). On
    /// failure, PERSISTS the merged batch back to disk through the ``store`` (AC1 durable fallback) —
    /// `drain()` already cleared both surfaces, so re-persisting makes disk the single source of truth
    /// for the failed batch (never half-in-memory/half-on-disk), and a later flush/drain re-delivers
    /// it disk-first. A flush with nothing on disk or in memory is a no-op (no upload, no event).
    private func flush() async {
        let envelopes = await drain()
        guard !envelopes.isEmpty else { return }
        do {
            try await uploader.upload(envelopes)
            // Delivered event count == every event across every visitor of every merged envelope (AC8) —
            // the true count shipped, which folds in any disk-recovered events alongside the buffered
            // ones. `EventBus` is an `actor`, so the `package` `fire(_:payload:)` is actor-isolated and
            // awaited here (matching `ExperienceManager`'s `await eventBus.fire(...)` caller).
            let eventCount = envelopes.reduce(0) { partial, event in
                partial + event.visitors.reduce(0) { $0 + $1.events.count }
            }
            await eventBus.fire(
                .apiQueueReleased,
                payload: .apiQueueReleased(ApiQueueReleasedPayload(eventCount: eventCount))
            )
        } catch {
            // Durable fallback (AC1): `drain()` already cleared disk AND buffer, so re-persist the
            // merged batch to make disk the single source of truth for the failed events — never
            // simultaneously half-in-memory/half-on-disk. A later flush/drain re-delivers it disk-first.
            // `try?`: a persist error degrades to a dropped batch rather than throwing out of the
            // unstructured flush Task (matches the no-throw store philosophy).
            try? await store.persist(envelopes)
        }
    }

    /// One timer iteration: sleep the configured interval, then flush. Awaiting `clock.sleep` here
    /// (an actor-isolated method) lets a stepping ``Clock`` release exactly one tick per `fireNext()`
    /// and records the requested interval, so a test can assert the loop slept the configured value.
    private func runTimerTick() async {
        await clock.sleep(milliseconds: releaseIntervalMs)
        await flush()
    }
}
