// ConfigStore.swift
// Minimal config-presence/ready-gate actor (Epic 2 / Story 2; expanded in Story 2.3).
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Owns the "config is present" state and the one-shot ready gate.
///
/// Config-type-agnostic by design (Decision D4): there is no `ProjectConfig` type yet, so
/// ``setConfig()`` takes no payload — it only flips the ready flag, fires `.ready` once, and
/// resumes any ``waitForReady()`` waiters. Story 2.3 replaces the no-arg ``setConfig()`` with
/// a typed `ProjectConfig` parameter.
///
/// All mutable state (`isReady`, `continuations`) is actor-isolated, so the ready gate is
/// race-free with no locks (AR12).
public actor ConfigStore {
    /// The owned bus on which `.ready` is fired exactly once.
    private let eventBus: EventBus
    /// Whether the first config has landed. Once `true`, stays `true`.
    private var isReady = false
    /// Waiters suspended in ``waitForReady()`` before config arrived.
    private var continuations: [CheckedContinuation<Void, Error>] = []

    /// Creates a store that fires `.ready` on the supplied bus.
    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    /// Marks the first config as present: fires `SystemEvent.ready` exactly once via the owned
    /// ``EventBus`` and resumes every ``waitForReady()`` waiter. Subsequent calls are no-ops
    /// (the gate latches), so `.ready` never re-fires. `async` because firing on the bus actor
    /// is an `await`ed cross-actor call. Story 2.3 replaces the no-arg form with a typed
    /// `ProjectConfig` parameter.
    public func setConfig() async {
        guard !isReady else { return }
        isReady = true
        await eventBus.fire(.ready, payload: .ready(ReadyPayload()))
        for continuation in continuations {
            continuation.resume()
        }
        continuations.removeAll()
    }

    /// Suspends until the first ``setConfig()``; returns immediately if config is already
    /// present. Resumes via the same actor-isolated continuation the gate stores.
    public func waitForReady() async throws {
        if isReady { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuations.append(continuation)
        }
    }
}
