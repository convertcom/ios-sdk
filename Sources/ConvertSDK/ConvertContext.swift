// ConvertContext.swift
// Visitor-scoped experimentation context (Epic 2 / Story 2 — stub).
// Real bucketing, feature resolution, and tracking arrive in Epics 3–4.

import Foundation

/// A visitor-scoped handle for running experiences/features and tracking conversions.
///
/// Story 2.2 ships the public surface as a stub: every method returns its DEGRADED value and
/// never throws (AOD-6 — the public API never surfaces a thrown error to callers), so an
/// integration compiles and runs against the final signatures before the Epic 3–4 engines
/// land. Holds its owning ``ConvertSDK`` by a `private let`; since the SDK does not hold the
/// context back, the reference is acyclic, and because ``ConvertSDK`` is `Sendable` this class
/// is `Sendable` with NO `@unchecked` and no suppression.
public final class ConvertContext: Sendable {
    /// The SDK that created this context. Strong and immutable: acyclic (the SDK holds no
    /// back-reference) and `Sendable` (``ConvertSDK`` is `Sendable`).
    private let sdk: ConvertSDK

    /// Binds the context to its creating SDK. Created only via ``ConvertSDK/createContext(visitorId:attributes:)``.
    internal init(sdk: ConvertSDK) {
        self.sdk = sdk
    }

    /// Whether event delivery is enabled for this context's SDK (FR6 static `network.tracking`).
    ///
    /// The real gate a future `eventSink.enqueue` call site checks: when `false`, bucketing/decisioning
    /// still runs and returns decisions, but produced tracking events are NOT enqueued (suppression is a
    /// CALLER concern here, not an `EventQueue` concern). The enqueue sites arrive in Epics 3-4; this hook
    /// is scaffolded now so the toggle is already in place when they do (Story 2.4 Task 4 / AC8).
    internal func trackingEnabled() -> Bool {
        sdk.networkTrackingEnabled
    }

    /// Runs one experience and returns the bucketed ``Variation``, or `nil` when none applies.
    /// Stub: returns `nil` (degraded) until Epic 3 wires bucketing.
    public func runExperience(_ key: String, enableTracking: Bool = true) async -> Variation? {
        // [WARN] ConvertContext.runExperience: not yet implemented (Epic 3).
        // tracking toggle guard (FR6): guard trackingEnabled() else { return nil }
        //   — wired when Epics 3-4 add eventSink.enqueue
        nil
    }

    /// Runs every applicable experience and returns the bucketed ``Variation``s. Stub: returns
    /// `[]` (degraded) until Epic 3 wires bucketing.
    public func runExperiences(enableTracking: Bool = true) async -> [Variation] {
        // [WARN] ConvertContext.runExperiences: not yet implemented (Epic 3).
        // tracking toggle guard (FR6): guard trackingEnabled() else { return [] }
        //   — wired when Epics 3-4 add eventSink.enqueue
        []
    }

    /// Resolves one feature flag and returns its ``BucketedFeature``. Non-optional by
    /// contract, so the stub returns a DEGRADED feature — disabled, empty variables — rather
    /// than throwing (AOD-6). Real resolution arrives in Epic 4.
    public func runFeature(_ key: String, enableTracking: Bool = true) async -> BucketedFeature {
        // [WARN] ConvertContext.runFeature: not yet implemented (Epic 4).
        BucketedFeature(id: "", key: key, status: .disabled, variables: [:])
    }

    /// Resolves every feature flag and returns its ``BucketedFeature``s. Stub: returns `[]`
    /// (degraded) until Epic 4 wires feature resolution.
    public func runFeatures(enableTracking: Bool = true) async -> [BucketedFeature] {
        // [WARN] ConvertContext.runFeatures: not yet implemented (Epic 4).
        []
    }

    /// Tracks a conversion for `goalKey` with optional ``GoalData``. Stub: no-op until Epic 4
    /// wires the tracking pipeline.
    public func trackConversion(_ goalKey: String, goalData: GoalData? = nil) async {
        // [WARN] ConvertContext.trackConversion: not yet implemented (Epic 4).
        // tracking toggle guard (FR6): guard trackingEnabled() else { return }
        //   — wired when Epics 3-4 add eventSink.enqueue
    }

    /// Sets the default visitor ``Segments``. Stub: no-op until Epic 4 wires segmentation.
    public func setDefaultSegments(_ segments: Segments) {
        // [WARN] ConvertContext.setDefaultSegments: not yet implemented (Epic 4).
    }

    /// Sets the custom segment identifiers for the visitor. Stub: no-op until Epic 4 wires
    /// custom segmentation.
    public func setCustomSegments(_ segmentIds: [String]) {
        // [WARN] ConvertContext.setCustomSegments: not yet implemented (Epic 4).
    }
}
