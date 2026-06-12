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
/// `internal`: constructed ONLY inside the same-module
/// ``ExperienceManager/makeDefault(decisionStore:eventBus:logger:)`` factory, so it never needs to
/// cross the module boundary — keeping the newly-public surface minimal (the factory is the one
/// public entry point cross-module callers see). A `struct` with no stored state is trivially
/// `Sendable` with no suppression.
internal struct NoopEventSink: EventSink {
    /// Discards the entry. Intentionally empty — see the type doc. (The parameterless initializer is
    /// synthesized: a stateless `internal struct` gets a default `init()` automatically.)
    func enqueue(_ event: TrackingEventEntry) async {
        // No-op: every produced entry is discarded until Epic 5's `EventQueue` is wired.
    }
}
