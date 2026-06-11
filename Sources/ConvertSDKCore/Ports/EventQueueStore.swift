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
    /// Loads the persisted queue, returning an empty array when nothing is stored.
    func load() async throws -> [TrackingEvent]

    /// Persists the given queue atomically, replacing any prior contents.
    func save(_ events: [TrackingEvent]) async throws
}
