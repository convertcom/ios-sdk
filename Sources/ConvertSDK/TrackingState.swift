// TrackingState.swift
// Runtime tracking-toggle state (Epic 5 / Story 5.6).
//
// Placement rationale: in the `ConvertSDK` platform target (NOT `ConvertSDKCore`) because:
//   (a) `EventQueue` propagation happens via a downcast in `ConvertSDK.setTrackingEnabled`
//       (the same `resolvedSink as? EventQueue` pattern `LifecycleObserver` already uses) —
//       keeping the downcast in the platform layer avoids a Core↔Platform circular dependency;
//   (b) `ConvertConfiguration` (Core) is immutable — the runtime flag supplements it here
//       in the platform layer, not by mutating Core types;
//   (c) the `TrackingState` reference is held as a `let` on `ConvertSDK`, so the class stays
//       an all-`let` Sendable final class with NO `@unchecked Sendable`.

/// Actor-isolated runtime tracking flag.
///
/// Owns the single mutable bit that `ConvertSDK.setTrackingEnabled(_:)` flips and
/// `ConvertSDK.isTrackingEnabled()` reads. Held as a `let` on `ConvertSDK`, so the SDK
/// stays an all-`let` `Sendable final class` — the actor REFERENCE is immutable; only the
/// actor-isolated `enabled` property mutates.
///
/// Seeded from `ConvertConfiguration.networkTracking` at init so the first
/// `isTrackingEnabled()` read returns the configured value even before any
/// `setTrackingEnabled` call. [Source: Story 5.6 / AC3]
actor TrackingState {
    /// The current runtime tracking flag.
    private(set) var enabled: Bool

    /// Creates the state, seeding it from the init-time `networkTracking` value.
    /// - Parameter initialValue: The `ConvertConfiguration.networkTracking` flag set at SDK init.
    init(initialValue: Bool) {
        self.enabled = initialValue
    }

    /// Replaces the tracking flag. Called by `ConvertSDK.setTrackingEnabled(_:)`.
    /// [Source: Story 5.6 / AC1, AC2, AC3]
    func set(_ value: Bool) {
        enabled = value
    }
}
