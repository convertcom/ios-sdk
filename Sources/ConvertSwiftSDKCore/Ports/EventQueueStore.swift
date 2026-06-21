// EventQueueStore.swift
// Port: durable persistence for the pending-event queue.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// Coordinated, atomic persistence for the pending tracking-event queue.
///
/// The concrete adapter (Epic 2) reads and writes the queue file atomically so a crash or
/// concurrent access never leaves a torn payload on disk. Pure logic treats the queue as a
/// load/save pair over the existing ``TrackingEvent`` type and stays unaware of the file
/// location or serialization format.
public protocol EventQueueStore: Sendable {
    /// Loads the persisted queue, returning an empty array when nothing is stored. A file that
    /// exists but fails to decode (corruption) is discarded and surfaced as `[]` — never thrown
    /// (FR51 / NFR13): the SDK degrades to an empty queue rather than crashing on bad bytes.
    func load() async throws -> [TrackingEvent]

    /// Persists the given queue atomically, replacing any prior contents. An empty array is
    /// equivalent to ``clear()`` (no `[]` JSON file is left behind).
    func persist(_ events: [TrackingEvent]) async throws

    /// Removes the persisted queue file entirely (equivalent to `persist([])`). Total / no-throw:
    /// erasing an already-absent queue is a successful no-op.
    func clear() async throws

    // MARK: - Background-upload in-flight marker (Story 5.3 / F-052 — cross-path exactly-once)
    //
    // A durable background `URLSession` upload streams the queue file from disk and snapshots it at
    // task creation, so clearing the file afterward does NOT cancel the in-flight upload. Without
    // coordination, the foreground-recovery flush (`drain()`) and cold-start recovery (`start()`) read
    // the SAME file disk-first and re-deliver it — double-delivery. These three operations persist a
    // marker, sibling to the queue file (so it survives process death), that records "a background
    // upload of the queue file is outstanding": set when the upload is enqueued, cleared by the
    // background reconcile on EVERY outcome, and consulted by `drain()` / `start()` to decline reading
    // or clearing the file while the upload is outstanding.

    /// Records that a durable background upload of the queue file is outstanding (enqueued, not yet
    /// reconciled), so the recovery paths decline to read or clear the file until it is cleared.
    func markBackgroundUploadInFlight() async throws

    /// Clears the in-flight marker. Called by the background reconcile on EVERY outcome (2xx, non-2xx,
    /// transport error), releasing the queue file back to the foreground-recovery / cold-start paths.
    /// Total / no-throw in spirit: clearing an absent marker is a successful no-op.
    func clearBackgroundUploadInFlight() async throws

    /// Whether a durable background upload of the queue file is currently outstanding. A missing marker
    /// (the common case) and any unreadable-marker error both surface as `false` — never stall delivery
    /// on an ambiguous read (if the marker is unreadable the queue file almost certainly is too, so
    /// there is nothing to double-deliver), matching ``load()``'s degrade-rather-than-throw philosophy.
    func isBackgroundUploadInFlight() async throws -> Bool
}
