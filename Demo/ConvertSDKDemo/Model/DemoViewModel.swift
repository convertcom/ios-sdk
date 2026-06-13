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

    /// The observed-events buffer the inspector's Events list renders, newest-first.
    ///
    /// Exposed read-only as the seam: Story 7.2 Task 3 wires the SDK event
    /// subscription that fills it, and Task 4 renders it. Empty for now.
    @Published private(set) var events: [InspectorEvent] = []

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
}
