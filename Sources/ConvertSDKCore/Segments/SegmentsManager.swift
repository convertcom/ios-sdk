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

    /// Merge-overlays the six string wire keys present in `dict` onto the visitor's existing
    /// segments; unknown keys are ignored with a WARN. Prior keys not in `dict` are retained. The
    /// existing `customSegments` array is untouched. [Source: AC1, AC9]
    public func setDefaultSegments(_ dict: [String: String], forVisitorKey key: String) async {
        var segments = await decisionStore.currentSegments(forVisitorKey: key)
        for (wireKey, value) in dict {
            switch wireKey {
            case "country":     segments.country = value
            case "browser":     segments.browser = value
            case "devices":     segments.devices = value
            case "source":      segments.source = value
            case "campaign":    segments.campaign = value
            case "visitorType": segments.visitorType = value
            default:
                logger.log(
                    level: .warn,
                    type: "SegmentsManager",
                    method: "setDefaultSegments",
                    message: "unknown segment key '\(wireKey)' ignored"
                )
            }
        }
        await decisionStore.setSegments(segments, forVisitorKey: key)
    }

    /// Appends `segmentIds` to the visitor's existing `customSegments` (dedup left to the backend,
    /// matching JS). The six string keys are untouched. [Source: AC2]
    public func setCustomSegments(_ segmentIds: [String], forVisitorKey key: String) async {
        var segments = await decisionStore.currentSegments(forVisitorKey: key)
        segments.customSegments = (segments.customSegments ?? []) + segmentIds
        await decisionStore.setSegments(segments, forVisitorKey: key)
    }

    /// The visitor's current segments. [Source: AC8]
    public func currentSegments(forVisitorKey key: String) async -> Segments {
        await decisionStore.currentSegments(forVisitorKey: key)
    }
}
