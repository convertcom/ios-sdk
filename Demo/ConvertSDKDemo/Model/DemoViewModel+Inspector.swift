import ConvertSDK
import Foundation

// MARK: - Event Inspector subscription (Story 7.2 / DEMO-3, Task 2)

extension DemoViewModel {

    /// Subscribes the Event Inspector to ALL ten ``SystemEvent`` cases, filling the
    /// ``events`` buffer as the SDK fires.
    ///
    /// One ``ConvertSDK/on(_:callback:)`` subscription per `SystemEvent.allCases`
    /// member; each returned ``EventListenerToken`` is retained in
    /// ``inspectorTokens`` so ``stopEventInspector()`` can unsubscribe every one
    /// (no leak). Call once at scene setup — the matching teardown is
    /// ``stopEventInspector()``; `deinit` deliberately does NOT unsubscribe (it
    /// cannot `await` the async ``ConvertSDK/off(_:)``).
    ///
    /// Idempotent: a no-op if already subscribed. Guarded on ``inspectorTokens``
    /// being non-empty, so a second call returns immediately without appending a
    /// duplicate set of listeners (which would double-record every event).
    ///
    /// Concurrency: the `on` callback is `@escaping @Sendable`, so it captures
    /// `self` *weakly* and hops onto the main actor with `Task { @MainActor in … }`
    /// before touching any state. ``EventBus`` already dispatches each callback as
    /// an independent `@MainActor` task, but the closure's own type is non-isolated
    /// `@Sendable`, so the explicit hop is what lets it call the `@MainActor`
    /// ``record(_:_:)`` without `@unchecked` and without a force unwrap.
    func startEventInspector() async {
        guard inspectorTokens.isEmpty else { return }
        for event in SystemEvent.allCases {
            let token = await sdk.on(event) { [weak self] payload in
                Task { @MainActor in
                    self?.record(event, payload)
                }
            }
            inspectorTokens.append(token)
        }
    }

    /// Unsubscribes every Event Inspector listener and clears the token store.
    ///
    /// Calls ``ConvertSDK/off(_:)`` (idempotent) for each token from
    /// ``startEventInspector()``, then empties ``inspectorTokens``. This is the sole
    /// teardown hook — `deinit` can't run it because `off` is `async`. Safe to call
    /// when nothing is subscribed (the loop is then empty).
    func stopEventInspector() async {
        for token in inspectorTokens {
            await sdk.off(token)
        }
        inspectorTokens.removeAll()
    }

    /// Records one observed SDK event into the ``events`` buffer (newest-first) and
    /// runs the queued→delivered correlation.
    ///
    /// Runs on the main actor (hopped into from the `@Sendable` `on` callback), so
    /// it mutates the `@Published` ``events`` directly. It:
    /// 1. builds an ``InspectorEvent`` whose initial ``InspectorEvent/Lifecycle`` is
    ///    ``InspectorEvent/Lifecycle/queued`` for the two networked events
    ///    (``SystemEvent/bucketing`` / ``SystemEvent/conversion``) and
    ///    ``InspectorEvent/Lifecycle/none`` for the other eight (including
    ///    ``SystemEvent/apiQueueReleased`` itself), with a redaction-safe
    ///    ``summary(for:)`` line;
    /// 2. inserts it at the front and trims the tail past ``inspectorEventCap``;
    /// 3. if the event is ``SystemEvent/apiQueueReleased``, flips every currently
    ///    ``InspectorEvent/Lifecycle/queued`` row to
    ///    ``InspectorEvent/Lifecycle/delivered`` — the release IS the delivered
    ///    signal, and the demo carries one in-flight batch at a time, so "release
    ///    marks the in-flight batch delivered" (the appended `.none` release row
    ///    itself is unaffected by the flip). When that flip actually moves ≥1 row, it
    ///    also bumps ``lastDeliveryAnnouncementID`` so the sheet posts the VoiceOver
    ///    "delivered" announcement (AC4); a release that flipped nothing does not.
    private func record(_ event: SystemEvent, _ payload: EventPayloadValue) {
        let initialLifecycle: InspectorEvent.Lifecycle
        switch event {
        case .bucketing, .conversion:
            initialLifecycle = .queued
        case .ready, .configUpdated, .apiQueueReleased, .segments,
             .locationActivated, .locationDeactivated, .audiences,
             .dataStoreQueueReleased:
            initialLifecycle = .none
        }

        let newEvent = InspectorEvent(
            event: event,
            summary: summary(for: payload),
            lifecycle: initialLifecycle
        )
        events.insert(newEvent, at: 0)
        if events.count > inspectorEventCap {
            events.removeLast(events.count - inspectorEventCap)
        }

        // The API delivery queue released its batch: flip the in-flight queued
        // networked rows to delivered. The just-inserted `.none` release row is
        // untouched (it is not `.queued`).
        if event == .apiQueueReleased {
            // Snapshot whether anything is actually in flight BEFORE the flip, so
            // the delivery announcement (AC4) fires only on a real Queued→Delivered
            // transition — not on a release that flipped nothing. The just-inserted
            // `.none` release row never counts here.
            let didFlip = events.contains { $0.lifecycle == .queued }
            for index in events.indices where events[index].lifecycle == .queued {
                events[index].lifecycle = .delivered
            }
            // Signal the sheet to announce "delivered" only when ≥1 row actually
            // flipped. The flip itself stays immediate/unconditional above (never
            // animation-gated); this only bumps the observed signal.
            if didFlip {
                lastDeliveryAnnouncementID = UUID()
            }
        }
    }

    /// Maps an ``EventPayloadValue`` to a redaction-safe, one-line summary for the
    /// row (NFR6 redaction posture).
    ///
    /// Includes only non-secret structural identifiers (experience / variation /
    /// goal ids, batch size, audience and location-property counts, location
    /// property keys). Visitor-identifying values are NEVER dumped raw: ``visitorId``
    /// is masked to a short prefix via ``maskedVisitor(_:)``. The ``ProjectConfig``
    /// snapshot and ``Segments`` contents (potential PII) are reduced to a presence
    /// note, never serialized. The switch is exhaustive over all ten cases (no
    /// `default:`) so every event's redacted shape is visible to a future reader.
    private func summary(for payload: EventPayloadValue) -> String {
        switch payload {
        case .ready:
            return "SDK ready"
        case .configUpdated(let value):
            return value.snapshot == nil
                ? "config updated — degraded / no snapshot"
                : "config updated — snapshot loaded"
        case .apiQueueReleased(let value):
            return "API queue released — batch of \(value.eventCount)"
        case .bucketing(let value):
            return "bucketed exp \(value.experienceId) → var \(value.variationId), "
                + maskedVisitor(value.visitorId)
        case .conversion(let value):
            return "converted goal \(value.goalId), " + maskedVisitor(value.visitorId)
        case .segments(let value):
            return "segments resolved, " + maskedVisitor(value.visitorId)
        case .locationActivated(let value):
            return "location activated — \(value.properties.count) propertie(s): "
                + value.properties.keys.sorted().joined(separator: ", ")
        case .locationDeactivated:
            return "location deactivated"
        case .audiences(let value):
            return "audiences resolved — \(value.audienceIds.count) audience(s), "
                + maskedVisitor(value.visitorId)
        case .dataStoreQueueReleased:
            return "data store queue released"
        }
    }

    /// Masks a `visitorId` to a non-identifying short prefix for display.
    ///
    /// Visitor ids are PII (NFR6), so the row shows at most the first six characters
    /// followed by an ellipsis (e.g. `visitor abc123…`), never the full value. An
    /// empty id is reported as `visitor <none>`.
    private func maskedVisitor(_ visitorId: String) -> String {
        guard !visitorId.isEmpty else { return "visitor <none>" }
        return "visitor \(visitorId.prefix(6))…"
    }
}
