// EventSink.swift
// Port: the decisioning -> queue enqueue seam.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// The decisioning → queue enqueue seam: where produced tracking entries are handed off
/// for eventual delivery.
///
/// This is the single inward-facing port the decisioning and conversion paths (Epics 3–4)
/// depend on. The `EventQueue` actor introduced in Story 5.1 conforms to this protocol,
/// but Epics 3–4 reference only ``EventSink`` — never the concrete actor type — so the
/// dependency arrow always points inward toward the core. The parameter is a
/// ``TrackingEventEntry`` (a single produced entry), not a fully assembled
/// ``TrackingEvent`` payload.
public protocol EventSink: Sendable {
    /// Hands a single produced entry to the queue for eventual delivery.
    func enqueue(_ event: TrackingEventEntry) async
}
