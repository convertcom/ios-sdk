// EventListenerToken.swift
// Opaque cancellable handle for an event subscription.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// An opaque, cancellable subscription handle.
///
/// Returned by `EventBus.on` and passed back to `EventBus.off` to cancel a subscription.
/// Tokens are created only by `EventBus.on` — the initializer is `internal`, so callers
/// cannot mint their own. `Hashable` and `Equatable` conformance lets the bus use tokens
/// directly as dictionary keys.
public struct EventListenerToken: Sendable, Hashable, Equatable {
    /// Process-unique identity of this subscription.
    internal let id: UUID

    /// Creates a fresh token with a unique identity. Only `EventBus.on` calls this.
    internal init() {
        self.id = UUID()
    }
}
