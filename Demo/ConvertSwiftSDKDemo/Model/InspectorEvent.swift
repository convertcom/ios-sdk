import ConvertSwiftSDK
import Foundation

/// One observed SDK event, as a single row in the Event Inspector's Events list
/// (Story 7.2 / DEMO-3).
///
/// A value model the inspector buffer (``DemoViewModel/events``) holds newest-first.
/// It can represent any of the SDK's 10 frozen ``SystemEvent`` cases via ``event``
/// and carries the ``lifecycle`` state the row's delivery badge renders.
///
/// `Sendable` + `Identifiable` + `Equatable`: it is created on the main actor from
/// the SDK's event stream and diffed by SwiftUI's `List`.
///
/// IMPORTANT: ``summary`` is ALWAYS a `toLoggable` / redaction-safe one-line
/// description — it must NEVER carry raw secrets (SDK key, visitor PII, raw
/// payload tokens). Task 3 fills it from the redacted, log-safe projection of the
/// event payload; until then it is empty. The model exists now as the seam.
struct InspectorEvent: Sendable, Identifiable, Equatable {

    /// Lifecycle of a single event row, driving the row's delivery badge.
    ///
    /// Only the two networked events — ``SystemEvent/bucketing`` and
    /// ``SystemEvent/conversion`` — move through ``queued`` then ``delivered`` as
    /// the API delivery queue flushes. Every other event is informational and
    /// carries ``none`` (no badge).
    enum Lifecycle: Sendable, Equatable {
        /// Non-networked event — no delivery badge is shown.
        case none
        /// A networked event accepted into the delivery queue, not yet flushed.
        case queued
        /// A networked event whose batch the delivery queue has flushed.
        case delivered
    }

    /// Stable SwiftUI list identity. A fresh `UUID` per observed event, so two
    /// occurrences of the same ``SystemEvent`` remain distinct rows.
    let id: UUID

    /// The SDK system event this row represents. Its `rawValue` is the wire name
    /// shown in the row (e.g. "bucketing", "config.updated").
    let event: SystemEvent

    /// Redaction-safe, one-line payload summary shown under the event name.
    ///
    /// ALWAYS the `toLoggable` / log-safe projection — never raw secrets. Empty
    /// until Task 3 populates it from the redacted payload.
    let summary: String

    /// Delivery lifecycle for the row's badge. ``Lifecycle/none`` for the eight
    /// informational events; ``Lifecycle/queued`` / ``Lifecycle/delivered`` for the
    /// two networked ones.
    ///
    /// The ONE mutable field: a networked row is appended ``Lifecycle/queued`` and
    /// later flipped to ``Lifecycle/delivered`` in place when the API delivery
    /// queue releases its batch (the queued→delivered correlation). Identity
    /// (``id``), ``event``, ``summary`` and ``capturedAt`` never change.
    var lifecycle: Lifecycle

    /// Capture time, used only to keep ordering stable when rows are inserted.
    /// The buffer is newest-first by insertion order; this is a tie-break aid, not
    /// a sort key the UI depends on.
    let capturedAt: Date

    /// - Parameters:
    ///   - id: List identity. Defaults to a fresh `UUID` per observed event.
    ///   - event: The SDK system event this row represents.
    ///   - summary: Redaction-safe one-line payload summary. Defaults to empty
    ///     (Task 3 fills it); MUST stay `toLoggable`-safe — never raw secrets.
    ///   - lifecycle: Delivery lifecycle for the badge. Defaults to
    ///     ``Lifecycle/none``; only networked events use `queued` / `delivered`.
    ///   - capturedAt: Capture time, used as an ordering tie-break. Defaults to now.
    init(
        id: UUID = UUID(),
        event: SystemEvent,
        summary: String = "",
        lifecycle: Lifecycle = .none,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.event = event
        self.summary = summary
        self.lifecycle = lifecycle
        self.capturedAt = capturedAt
    }
}
