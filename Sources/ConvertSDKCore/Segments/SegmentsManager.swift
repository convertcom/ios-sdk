// SegmentsManager.swift
// Visitor segment assignment for reporting (Epic 4 / Story 4).
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Manages visitor segment assignment for reporting.
///
/// A stateless `Sendable` struct (NOT an actor): it owns no mutable state — the injected
/// ``DecisionStore`` actor owns the persisted per-visitor `Segments`. ``setDefaultSegments(_:forVisitorKey:)``
/// MERGE-overlays the six string wire keys onto the visitor's existing segments (prior keys not in
/// the dict are retained, matching JS `data-manager.ts` `objectDeepMerge({...existing, ...new})`);
/// ``setCustomSegments(_:forVisitorKey:)`` APPENDS to `customSegments` (matching JS `segments-manager.ts`
/// `[...customSegments, ...segmentIds]`). Unknown keys are ignored with a WARN (AOD-6 — degrade,
/// never throw). [Source: AR14, FR28-30]
public struct SegmentsManager: Sendable {
    /// Visitor-keyed store that owns the persisted ``Segments`` this manager overlays.
    private let decisionStore: DecisionStore
    /// Log sink for the unknown-wire-key WARN.
    private let logger: any Logger

    /// Injects the decision store the segments are read from and written to, plus the log sink.
    public init(decisionStore: DecisionStore, logger: any Logger) {
        self.decisionStore = decisionStore
        self.logger = logger
    }

    /// Maps the six string wire keys present in `dict` into a partial ``Segments`` overlay (unknown
    /// keys are ignored with a WARN), then hands it to ``DecisionStore/mergeSegments(_:forVisitorKey:)``,
    /// which overlays and persists it as ONE non-suspending actor step. The key mapping is pure (no
    /// shared state); the atomic read-overlay-write lives in the actor, so two concurrent setters on
    /// the same visitor cannot lose an overlay (F-172). Prior keys not in `dict` are retained; the
    /// existing `customSegments` array is untouched. [Source: AC1, AC9, AC15]
    public func setDefaultSegments(_ dict: [String: String], forVisitorKey key: String) async {
        var overlay = Segments()
        for (wireKey, value) in dict {
            switch wireKey {
            case "country":     overlay.country = value
            case "browser":     overlay.browser = value
            case "devices":     overlay.devices = value
            case "source":      overlay.source = value
            case "campaign":    overlay.campaign = value
            case "visitorType": overlay.visitorType = value
            default:
                logger.log(
                    level: .warn,
                    type: "SegmentsManager",
                    method: "setDefaultSegments",
                    message: "unknown segment key '\(wireKey)' ignored"
                )
            }
        }
        await decisionStore.mergeSegments(overlay, forVisitorKey: key)
    }

    /// Appends `segmentIds` to the visitor's existing `customSegments` via
    /// ``DecisionStore/appendCustomSegments(_:forVisitorKey:)``, which reads, appends, and persists as
    /// ONE non-suspending actor step so concurrent appends cannot drop an id (F-172). Dedup is left to
    /// the backend (matching JS); the six string keys are untouched. [Source: AC2, AC15]
    public func setCustomSegments(_ segmentIds: [String], forVisitorKey key: String) async {
        await decisionStore.appendCustomSegments(segmentIds, forVisitorKey: key)
    }

    /// The visitor's current segments. [Source: AC8]
    public func currentSegments(forVisitorKey key: String) async -> Segments {
        await decisionStore.currentSegments(forVisitorKey: key)
    }
}
