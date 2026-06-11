// EventBus.swift
// In-process pub/sub for internal SDK system events.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// In-process publish/subscribe bus for `SystemEvent`s.
///
/// Shared mutable state (the subscriber table) is actor-isolated, so concurrent
/// `on`/`off`/`fire` calls are safe by construction with no manual locks (AR12).
/// Subscriber invocation order for a given event is unspecified: each callback is
/// dispatched as an independent `MainActor` task.
public actor EventBus {
    /// event -> (token -> callback). Actor-isolated; the sole shared mutable state.
    private var subscribers: [SystemEvent: [EventListenerToken: @Sendable (EventPayloadValue) -> Void]] = [:]

    /// Creates an empty event bus.
    public init() {}

    /// Subscribes `callback` to `event`. Returns an opaque token; pass it to `off` to cancel.
    public func on(
        _ event: SystemEvent,
        callback: @escaping @Sendable (EventPayloadValue) -> Void
    ) -> EventListenerToken {
        let token = EventListenerToken()
        subscribers[event, default: [:]][token] = callback
        return token
    }

    /// Cancels the subscription identified by `token`. Idempotent: a token that is absent
    /// (already removed, or from another bus) is a harmless no-op.
    public func off(_ token: EventListenerToken) {
        for event in subscribers.keys {
            subscribers[event]?.removeValue(forKey: token)
        }
    }

    /// Dispatches `payload` to every callback registered for `event`.
    /// STUB: currently a no-op — real dispatch lands in the GREEN phase.
    internal func fire(_ event: SystemEvent, payload: EventPayloadValue) {
        // TODO: replaced by GREEN phase — dispatch to subscribers on MainActor.
        _ = event
        _ = payload
    }
}
