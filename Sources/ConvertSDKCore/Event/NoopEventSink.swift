// NoopEventSink.swift
// A no-op `EventSink` implementation (Epic 3 / Story 4 stand-in; bead bd-2pb).
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// An ``EventSink`` that discards every enqueued entry.
///
/// The production default sink until Epic 5's `EventQueue` (which will conform to ``EventSink``)
/// is wired. Bucketing / conversion events are PRODUCED at the ``EventSink`` boundary — the
/// decisioning → queue seam this SDK owns (``BucketingManager`` performs the single bucketing
/// enqueue at that port) — but have no delivery destination yet, so they no-op here. The seam is
/// exercised correctly; only the downstream queue is absent.
///
/// Mirrors ``NoopLogger`` / the ephemeral file stores: a stand-in so a required port is ALWAYS
/// satisfiable, letting decisioning ship now without faking the (not-yet-built) queue. Replacing
/// this with the real `EventQueue` in Epic 5 is a one-line swap at the single construction site
/// (``ExperienceManager/makeDefault(decisionStore:eventBus:logger:)``).
///
/// `public`: besides the same-module
/// ``ExperienceManager/makeDefault(decisionStore:eventBus:logger:)`` factory that builds it for the
/// bucketing path, it now also serves as the cross-module DEFAULT ``EventSink`` for
/// ``ConvertSDK/init`` (the outer `ConvertSDK` target's conversion seam defaults `eventSink:` to a
/// `NoopEventSink()`). A stateless default sink must therefore be constructible across the module
/// boundary, so the type and its initializer are `public`. A `struct` with no stored state is
/// trivially `Sendable` with no suppression.
public struct NoopEventSink: EventSink {
    /// Creates the no-op sink. Explicit `public` initializer: a `public` struct does not expose its
    /// synthesized memberwise/default init across the module boundary, so the cross-module default in
    /// ``ConvertSDK/init`` needs this declared `init()` to call `NoopEventSink()`.
    public init() {}

    /// Discards the entry. Intentionally empty — see the type doc. `public` so it is the protocol
    /// witness for ``EventSink/enqueue(_:)`` across the module boundary.
    public func enqueue(_ event: TrackingEventEntry) async {
        // No-op: every produced entry is discarded until Epic 5's `EventQueue` is wired.
    }
}
