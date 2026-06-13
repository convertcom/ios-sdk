import ConvertSDK
import SwiftUI

/// App-level state for the Convert SDK demo.
///
/// Owns the single ``ConvertSDK`` instance (keeping the SDK out of the App
/// struct and out of any View's value semantics) and publishes a coarse
/// ``ConfigState`` the UI can observe. `@MainActor` because it publishes UI
/// state that SwiftUI observes on the main actor.
///
/// Story 7.1 scope: construct the SDK against the FS-Test-Proj staging project
/// and kick off readiness *best-effort*. It deliberately does NOT act on the
/// outcome of `ready()` beyond flipping a minimal published state — the real
/// config state machine (timeout, WARN-before-READY, retries) is Story 7.6.
@MainActor
final class DemoViewModel: ObservableObject {

    /// The single SDK instance, owned for the app's lifetime.
    ///
    /// `ConvertSDK` is `final class … Sendable`, so it is held directly with no
    /// `@unchecked` wrapper under `SWIFT_STRICT_CONCURRENCY: complete`.
    let sdk: ConvertSDK

    /// Coarse readiness signal for the UI. Minimal Story 7.1 stub; Story 7.6
    /// replaces the transitions here with the full state machine.
    @Published private(set) var configState: ConfigState = .loading

    /// The two segments of the Event Inspector sheet (Story 7.2 / DEMO-3).
    ///
    /// `CaseIterable` + `Identifiable` so it drives a segmented `Picker` directly;
    /// the `title` is the visible segment label and the VoiceOver word.
    enum InspectorSegment: CaseIterable, Identifiable {
        /// The observed-events list.
        case events
        /// The live-log stream.
        case logs

        /// Stable identity for the `Picker` / `ForEach`.
        var id: Self { self }

        /// The segment's visible label, e.g. "Events" / "Logs".
        var title: String {
            switch self {
            case .events: return "Events"
            case .logs: return "Logs"
            }
        }
    }

    /// Whether the Event Inspector sheet is presented. Drives the sheet from any
    /// tab's toolbar button, so the presentation state survives tab switches
    /// instead of resetting per-tab (AC1).
    @Published var isInspectorPresented: Bool = false

    /// The Event Inspector segment last chosen by the user. Lives here — not in a
    /// per-present `@State` — so it PERSISTS across present/dismiss cycles and tab
    /// switches (AC1). It is deliberately never reset on dismiss.
    @Published var selectedSegment: InspectorSegment = .events

    /// A "a delivery just happened" signal the sheet observes to post the VoiceOver
    /// "delivered" announcement (AC4).
    ///
    /// Bumped to a fresh `UUID` by ``record(_:_:)`` ONLY when an `.apiQueueReleased`
    /// actually flips ≥1 ``InspectorEvent/Lifecycle/queued`` row to
    /// ``InspectorEvent/Lifecycle/delivered`` — never on a plain append, and never on
    /// a release that flipped nothing. The model only *signals*; the View layer
    /// (``EventInspectorSheet``) owns the actual `UIAccessibility.post` so this view
    /// model stays free of UIKit / `UIAccessibility`. The announcement is therefore
    /// NOT animation-gated: it fires on every real flip regardless of Reduce Motion.
    @Published private(set) var lastDeliveryAnnouncementID = UUID()

    /// The observed-events buffer the inspector's Events list renders, newest-first.
    ///
    /// Filled by ``startEventInspector()``'s subscription (Story 7.2 Task 3) and
    /// rendered by Task 4. Exposed read-only — only the event handler here mutates
    /// it. Bounded at ``inspectorEventCap`` newest rows (see below).
    @Published private(set) var events: [InspectorEvent] = []

    /// Live subscription tokens for the Event Inspector, one per ``SystemEvent``
    /// case, held so ``stopEventInspector()`` can unsubscribe every one. Empty
    /// until ``startEventInspector()`` populates it; cleared on stop.
    private var inspectorTokens: [EventListenerToken] = []

    /// Upper bound on ``events`` so the demo buffer can't grow without limit over a
    /// long session. On insert, the oldest rows past this many are trimmed from the
    /// tail (``events`` is newest-first, so the tail is the oldest).
    private let inspectorEventCap = 200

    init() {
        // FS-Test-Proj staging: account 10035569 / project 10034190. The
        // "account/project" sdkKey form resolves to the live config URL
        // {apiConfigEndpoint}/config/10035569/10034190 on the default CDN
        // (cdn-4.convertexperiments.com/api/v1). No secret is required for
        // the demo to compile and launch-init; live decisioning is Story 7.3+.
        let configuration = ConvertConfiguration(sdkKey: "10035569/10034190")
        sdk = ConvertSDK(configuration: configuration)
    }

    /// Fires SDK readiness best-effort without blocking the UI.
    ///
    /// This method is `@MainActor` (inherited from the type), so it runs on the
    /// main actor; `ready()` is awaited (it suspends; it does not block the main
    /// actor — the SDK performs its network I/O internally) and
    /// the throw is swallowed in Story 7.1 — a transient network failure resolves
    /// degraded rather than throwing, and the only thrown case (unrecoverable
    /// config) is surfaced through ``ConfigState`` here as a placeholder. Story 7.6
    /// owns the real error surfacing.
    func start() async {
        do {
            try await sdk.ready()
            configState = .loaded
        } catch {
            configState = .failed(reason: error.localizedDescription)
        }
    }

    /// Presents the Event Inspector sheet from any tab's toolbar button.
    ///
    /// Sets only ``isInspectorPresented`` — ``selectedSegment`` is left untouched
    /// so the last-chosen segment survives the re-present (AC1). There is
    /// deliberately no matching reset on dismiss; preserving the segment across
    /// present/dismiss cycles IS the persistence requirement.
    func presentInspector() {
        isInspectorPresented = true
    }

    // MARK: - Event Inspector subscription (Story 7.2 / DEMO-3, Task 2)

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
