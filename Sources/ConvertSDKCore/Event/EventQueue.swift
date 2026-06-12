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
    public init(
        accountId: String,
        projectId: String,
        batchSize: Int = Defaults.batchSize,
        releaseIntervalMs: Int = Defaults.releaseIntervalMs,
        uploader: any EventUploader,
        eventBus: EventBus,
        trackingEnabled: Bool = true,
        clock: any Clock = SystemClock()
    ) {
        self.accountId = accountId
        self.projectId = projectId
        self.batchSize = batchSize
        self.releaseIntervalMs = releaseIntervalMs
        self.uploader = uploader
        self.eventBus = eventBus
        self.trackingEnabled = trackingEnabled
        self.clock = clock
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

    // MARK: - Drain

    /// Assembles the buffered entries into the canonical envelope and empties the buffer in ONE
    /// actor step (AC1).
    ///
    /// Entries are grouped per visitor in first-seen order; `nil` segments became the empty map at
    /// enqueue. Returns a single-element `[TrackingEvent]` (there is one account/project, so one
    /// envelope) whose `visitors` carry their grouped events. A second call returns `[]` — the read
    /// and clear happen with no suspension between them, so no entry is ever drained twice.
    ///
    /// - Returns: One assembled ``TrackingEvent`` wrapping the drained entries, or `[]` when empty.
    public func drain() -> [TrackingEvent] {
        assemble(drainEntries())
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

    /// Drains the buffer and ships the assembled batch through the ``uploader``.
    ///
    /// On success, fires ``SystemEvent/apiQueueReleased`` with the delivered event count (AC8). On
    /// failure, restores the drained entries to the FRONT of the buffer so their original order is
    /// preserved and a later flush re-delivers them (AC1 re-enqueue-on-failure). A flush of an empty
    /// buffer is a no-op (no upload, no event).
    private func flush() async {
        let drained = drainEntries()
        guard !drained.isEmpty else { return }
        let envelope = assemble(drained)
        do {
            try await uploader.upload(envelope)
            // Delivered event count == the number of buffered entries shipped (AC8). The buffer
            // holds one entry per produced event, so `drained.count` is the event count. `EventBus`
            // is an `actor`, so the `package` `fire(_:payload:)` is actor-isolated and awaited here
            // (matching `ExperienceManager`'s `await eventBus.fire(...)` caller).
            await eventBus.fire(
                .apiQueueReleased,
                payload: .apiQueueReleased(ApiQueueReleasedPayload(eventCount: drained.count))
            )
        } catch {
            // Restore the drained entries ahead of any that arrived during the upload, preserving
            // their original relative order for re-delivery.
            buffer = drained + buffer
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
