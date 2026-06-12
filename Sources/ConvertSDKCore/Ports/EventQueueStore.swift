// EventQueueStore.swift
// Port: durable persistence for the pending-event queue.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

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
}
