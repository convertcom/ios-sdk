// SystemEvent.swift
// The frozen JS-parity set of internal system event names.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// The frozen JS-parity set of internal system events (FR52).
///
/// ```swift
/// // given a constructed `sdk`
/// let token = await sdk.on(.ready) { _ in print("ready") }
/// ```
///
/// Raw values are the exact JS wire strings, source-verified against
/// `system-events.ts:12-23`. This set is a frozen contract: NO new case may ever be
/// added. In particular there is deliberately no `systemError` / `configStale` case —
/// errors never surface as a system event; they surface via the Logger port only
/// (AOD-3 / AR8). The 10 members and their raw values must never be reordered, renamed,
/// added to, or removed.
public enum SystemEvent: String, Sendable, CaseIterable {
    /// SDK finished initialization and is ready to serve.
    case ready                   = "ready"
    /// The remote configuration was (re)loaded.
    case configUpdated           = "config.updated"
    /// The API delivery queue flushed a batch.
    case apiQueueReleased        = "api.queue.released"
    /// A visitor was bucketed into a variation.
    case bucketing               = "bucketing"
    /// A conversion goal was tracked.
    case conversion              = "conversion"
    /// Visitor segmentation attributes were resolved.
    case segments                = "segments"
    /// An experience location became active for the visitor.
    case locationActivated       = "location.activated"
    /// An experience location became inactive for the visitor.
    case locationDeactivated     = "location.deactivated"
    /// Audience membership was resolved for the visitor.
    case audiences               = "audiences"
    /// The data-store persistence queue flushed.
    case dataStoreQueueReleased  = "datastore.queue.released"
}
