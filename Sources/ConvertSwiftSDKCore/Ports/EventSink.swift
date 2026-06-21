// EventSink.swift
// Port: the decisioning -> queue enqueue seam.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// The decisioning → queue enqueue seam: where produced tracking entries are handed off
/// for eventual delivery.
///
/// This is the single inward-facing port the decisioning and conversion paths (Epics 3–4)
/// depend on. The `EventQueue` actor introduced in Story 5.1 conforms to this protocol,
/// but Epics 3–4 reference only ``EventSink`` — never the concrete actor type — so the
/// dependency arrow always points inward toward the core. The entry parameter is a
/// ``TrackingEventEntry`` (a single produced entry), not a fully assembled
/// ``TrackingEvent`` payload.
///
/// The seam carries the grouping key (`visitorId`) and the optional per-visitor `segments`
/// alongside each entry — matching the JS SDK's `enqueue(visitorId, eventRequest, segments?)`
/// shape (`api-manager.ts:182`) — so the conforming queue can group entries by visitor into the
/// canonical `visitors:[{visitorId, segments, events}]` delivery envelope. The producers already
/// hold this identity; widening the port lets it cross the seam rather than being reconstructed
/// downstream. The grouping itself belongs to the conforming ``EventQueue`` actor, not to this
/// port: the producers pass identity-per-entry and stay oblivious to how entries are batched.
public protocol EventSink: Sendable {
    /// Hands a single produced entry to the queue for eventual delivery, tagged with the
    /// visitor it belongs to and that visitor's optional segments.
    ///
    /// - Parameters:
    ///   - event: The single produced ``TrackingEventEntry`` (bucketing or conversion).
    ///   - visitorId: The visitor the entry belongs to — the key the conforming queue groups on.
    ///   - segments: The visitor's segments for the canonical envelope, or `nil` when none apply.
    func enqueue(_ event: TrackingEventEntry, for visitorId: String, segments: [String: String]?) async
}
