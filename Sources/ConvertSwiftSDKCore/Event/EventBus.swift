// EventBus.swift
// In-process pub/sub for internal SDK system events.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

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
    ///
    /// Non-blocking: each callback is delivered as an independent `MainActor` task
    /// (fire-and-forget), so callers on any actor/thread may call `fire` and it returns
    /// immediately without awaiting the callbacks. Subscriber invocation order is
    /// unspecified. When no callbacks are registered for `event`, this is a no-op.
    ///
    /// `package` (NOT `public`): the in-package firers — ``ConfigStore`` / ``ExperienceManager``
    /// inside this module, AND ``ConvertContext`` in the sibling `ConvertSwiftSDK` target (the conversion
    /// seam fires `.conversion` here) — must reach it, but external SDK consumers must NOT be able to
    /// spoof system events onto the bus. `package` grants exactly the in-package visibility the
    /// conversion path needs while keeping `fire` off the SDK's public surface (the public bus API
    /// stays `on`/`off` only). Mirrors ``VisitorContextManager``'s `package` access, already consumed
    /// cross-target by `ConvertSwiftSDK.createContext`.
    package func fire(_ event: SystemEvent, payload: EventPayloadValue) {
        guard let callbacks = subscribers[event] else { return }
        for callback in callbacks.values {
            Task { @MainActor in
                callback(payload)
            }
        }
    }
}
