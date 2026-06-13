import SwiftUI
import UIKit

/// The Event-Inspector bottom sheet (Story 7.2 / DEMO-3) — the real inspector
/// that replaces the earlier placeholder sheet.
///
/// It is ALWAYS a bottom sheet (presented via `.sheet` from every tab's
/// ``InspectorToolbar`` button) — never a pushed screen and never a sixth tab.
/// A segmented `Picker` switches between the Events list and the Logs stream;
/// the selection binds to the shared ``DemoViewModel/selectedSegment``, so the
/// chosen segment survives tab switches and re-presents (AC1) rather than
/// resetting per-present.
///
/// It owns its own `NavigationView` (stack style) so the "Event Inspector" title
/// and the trailing "Done" button render correctly inside a sheet on the iOS 15
/// deployment floor, and reads `\.dismiss` so Done closes the sheet regardless
/// of how it was presented. The system `.sheet` already supplies the grabber and
/// the sheet radius on iOS 15, so no iOS-16-only `.presentationDetents` /
/// `.presentationDragIndicator` are used.
struct EventInspectorSheet: View {

    /// Shared app-level state, injected at the app root. Supplies the observed
    /// ``DemoViewModel/events`` buffer and the persisted
    /// ``DemoViewModel/selectedSegment`` the segmented control binds to.
    @EnvironmentObject private var viewModel: DemoViewModel

    /// Sheet dismissal handle, supplied by the presenting `.sheet` modifier.
    @Environment(\.dismiss) private var dismiss

    /// Whether the user has Reduce Motion enabled (iOS 15 SwiftUI environment key).
    ///
    /// Read only to make the no-animation contract explicit: the Delivered flip is
    /// already an unconditional state change in ``DemoViewModel/record(_:_:)`` (no
    /// animation wraps it), so it stays visible under Reduce Motion by construction.
    /// This sheet adds NO animation to the badge change, so there is nothing to gate
    /// — but the value is captured here so the contract is visible to a future reader
    /// and so any later animated affordance MUST consult it before animating (AC4).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// VoiceOver focus anchor for "move focus INTO the sheet on present" (AC4).
    ///
    /// Bound to the segmented control — the sheet's first/primary interactive
    /// element — via `.accessibilityFocused`. Setting it `true` shortly after the
    /// sheet appears pulls VoiceOver focus onto "Inspector segment, …" instead of
    /// leaving focus on the dimmed presenter behind the sheet. The brief delay is
    /// deliberate: setting focus in the same run loop as the sheet's appearance is
    /// dropped because the sheet's accessibility tree is not built yet on iOS 15.
    @AccessibilityFocusState private var segmentFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: ConvertTheme.space4) {
                segmentPicker
                segmentBody
            }
            // A system material reads as sheet chrome on the iOS 15 floor (where
            // `.presentationBackground` does not exist), letting the underlying
            // context tint through the sheet rather than a flat opaque fill.
            .background(.ultraThinMaterial)
            .navigationTitle("Event Inspector")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            // Move VoiceOver focus into the sheet (onto the segmented control) once
            // it has appeared (AC4). `.task` inherits the View's main-actor
            // isolation, so setting the focus state is concurrency-clean under Swift
            // 6 strict concurrency; `Task.sleep` yields one short beat so the sheet's
            // accessibility tree exists before the focus request lands. The sleep is
            // best-effort — `try?` swallows the only thrown case (cancellation, e.g.
            // a fast dismiss), which simply skips the focus move with no force-unwrap.
            .task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                segmentFocused = true
            }
            // Announce "delivered" to VoiceOver the moment a Queued→Delivered flip
            // happens (AC4), so a VoiceOver user hears it WITHOUT navigating to the
            // row. The model bumps `lastDeliveryAnnouncementID` only on a real flip,
            // so this fires once per genuine delivery and never on a plain append.
            // It is NOT animation-gated — it fires regardless of Reduce Motion. The
            // UIKit `UIAccessibility.post` is the iOS-15-safe announcement path
            // (SwiftUI's `AccessibilityNotification.Announcement` is iOS 17+).
            .onChange(of: viewModel.lastDeliveryAnnouncementID) { _ in
                UIAccessibility.post(notification: .announcement, argument: "delivered")
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Segmented control

    /// The Events / Logs segmented control, bound to the shared view model so the
    /// selection persists across tab switches and re-presents (AC1).
    ///
    /// It iterates ``DemoViewModel/InspectorSegment/allCases``, labels each
    /// segment by its ``DemoViewModel/InspectorSegment/title``, and tags each by
    /// the case so the binding round-trips. The `.accessibilityLabel` names the
    /// control as a whole and `.accessibilityValue` states the current selection, so
    /// VoiceOver reads "Inspector segment, Events" / "…, Logs" explicitly rather than
    /// relying solely on the segmented `Picker`'s native option announcement (AC4).
    /// It also carries the `.accessibilityFocused` anchor so the sheet can pull focus
    /// here on present (see ``segmentFocused``).
    private var segmentPicker: some View {
        Picker("Inspector segment", selection: $viewModel.selectedSegment) {
            ForEach(DemoViewModel.InspectorSegment.allCases) { segment in
                Text(segment.title).tag(segment)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Inspector segment")
        .accessibilityValue(viewModel.selectedSegment.title)
        .accessibilityFocused($segmentFocused)
        .padding(.horizontal, ConvertTheme.space4)
        .padding(.top, ConvertTheme.space3)
    }

    // MARK: - Segment bodies

    /// The body for the currently selected segment.
    @ViewBuilder
    private var segmentBody: some View {
        switch viewModel.selectedSegment {
        case .events:
            eventsBody
        case .logs:
            logsBody
        }
    }

    /// The Events segment: the empty state when no events have been observed yet,
    /// otherwise the scrolling list of ``InspectorEventRow`` lifecycle rows.
    ///
    /// The buffer is already newest-first (``DemoViewModel/events`` inserts at
    /// index 0), so the list renders it as-is — no re-sort. `List` supplies the
    /// scrolling so the segment scrolls when events accrue, and each row wraps its
    /// mono payload rather than truncating (AC3: wrap or scroll, never truncate).
    @ViewBuilder
    private var eventsBody: some View {
        if viewModel.events.isEmpty {
            InspectorEmptyState(
                symbolName: "list.bullet.rectangle",
                title: "No events yet",
                message: "No events yet — run an experience or track a conversion."
            )
        } else {
            List(viewModel.events) { event in
                InspectorEventRow(event: event)
            }
            .listStyle(.plain)
        }
    }

    /// The Logs segment: a deliberately labeled placeholder.
    ///
    /// The live log stream is descoped from this story (Story 7.2b) — the SDK
    /// surface exposes no public logger-injection seam to capture log lines yet,
    /// so there is nothing live to render. The segment stays fully selectable so
    /// AC1's cross-tab segment persistence is still exercised through it.
    private var logsBody: some View {
        InspectorEmptyState(
            symbolName: "doc.plaintext",
            title: "Logs — not yet wired",
            message: "The live log stream arrives in a follow-up (Story 7.2b) "
                + "once the SDK exposes a log-capture seam."
        )
    }
}

/// One row in the Event Inspector's Events list (Story 7.2 / DEMO-3, AC2).
///
/// Renders a single observed ``InspectorEvent`` as: the event's wire name on top
/// (a readable label, not mono) with the lifecycle ``StatusBadge`` pinned to the
/// trailing edge, and the redaction-safe payload ``InspectorEvent/summary`` in SF
/// Mono beneath it.
///
/// Lifecycle → badge follows the model's contract: only the two networked events
/// carry a badge (``InspectorEvent/Lifecycle/queued`` → "Queued",
/// ``InspectorEvent/Lifecycle/delivered`` → "Delivered"); the eight informational
/// events are ``InspectorEvent/Lifecycle/none`` and carry NO badge at all (AC2:
/// "non-networked events carry no badge"). The mono summary wraps and grows
/// vertically rather than truncating at large Dynamic Type (AC3); an empty summary
/// renders no mono line.
///
/// For VoiceOver (AC4) the row is fused into ONE accessibility element via
/// `.accessibilityElement(children: .ignore)` so it announces "event, lifecycle"
/// (e.g. "bucketing, delivered") in a single move via ``rowAccessibilityLabel``,
/// rather than reading the name and the badge piecemeal. The badge stays VISIBLE —
/// only the spoken output is fused; sighted users still see the chip. The lifecycle
/// word is sourced from the row's own ``InspectorEvent/Lifecycle`` so meaning never
/// relies on color.
private struct InspectorEventRow: View {

    /// The observed event this row renders.
    let event: InspectorEvent

    var body: some View {
        VStack(alignment: .leading, spacing: ConvertTheme.space2) {
            HStack(alignment: .firstTextBaseline, spacing: ConvertTheme.space2) {
                Text(event.event.rawValue)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: ConvertTheme.space2)
                lifecycleBadge
            }
            if !event.summary.isEmpty {
                Text(event.summary)
                    .font(ConvertTheme.monospacedBody())
                    .foregroundStyle(.secondary)
                    // No `.lineLimit(1)`: the mono payload must wrap and grow
                    // vertically rather than truncate at large Dynamic Type (AC3).
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, ConvertTheme.space1)
        // Fuse the row into ONE VoiceOver element so it announces "event, lifecycle"
        // (e.g. "bucketing, delivered") in one move instead of reading the name and
        // the badge piecemeal (AC4). `children: .ignore` hides the child elements
        // from VoiceOver — the badge stays VISIBLE for sighted users; only the
        // spoken output changes. The visual layout above is untouched.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    /// The fused VoiceOver label for the whole row — "event, lifecycle" first so it
    /// matches AC4's "bucketing, delivered", with the redacted ``summary`` appended
    /// when present so the payload is still reachable in one element.
    ///
    /// The lifecycle word comes from the row's own ``InspectorEvent/Lifecycle`` (not
    /// the ``StatusBadge``, whose children are now ignored): `.queued` → "queued",
    /// `.delivered` → "delivered", and `.none` contributes NO lifecycle word because
    /// non-networked events have no delivery lifecycle. The wire name always leads
    /// and the lifecycle word, when present, immediately follows it so the
    /// "name, lifecycle" shape is stable regardless of the summary.
    private var rowAccessibilityLabel: String {
        let name = event.event.rawValue
        let head: String
        switch event.lifecycle {
        case .queued:
            head = "\(name), queued"
        case .delivered:
            head = "\(name), delivered"
        case .none:
            head = name
        }
        guard !event.summary.isEmpty else { return head }
        return "\(head). \(event.summary)"
    }

    /// The lifecycle ``StatusBadge`` for this row, or nothing for a non-networked
    /// (``InspectorEvent/Lifecycle/none``) event.
    ///
    /// The whole `Lifecycle` → badge mapping lives here in ONE switch so no
    /// badge-construction block is duplicated across rows; the ``StatusBadge``
    /// itself already owns the symbol/color/word per state.
    @ViewBuilder
    private var lifecycleBadge: some View {
        switch event.lifecycle {
        case .queued:
            StatusBadge("Queued", style: .queued)
        case .delivered:
            StatusBadge("Delivered", style: .delivered)
        case .none:
            // Non-networked event — AC2: no badge.
            EmptyView()
        }
    }
}

/// A centered icon + headline + secondary-line state, shared by the Events
/// empty state and the Logs placeholder so the two centered states do not
/// duplicate the same scaffold.
///
/// Mirrors the old placeholder's empty-state styling: a large secondary-tinted
/// SF Symbol, a headline title, and a centered secondary subheadline, padded on
/// the ``ConvertTheme`` grid and expanded to fill so it sits centered in the
/// sheet body.
private struct InspectorEmptyState: View {

    /// SF Symbol shown above the text (verified present on the iOS 15 floor).
    let symbolName: String

    /// Headline line.
    let title: String

    /// Secondary subheadline line, centered beneath the title.
    let message: String

    var body: some View {
        VStack(spacing: ConvertTheme.space3) {
            Image(systemName: symbolName)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                // decorative; the title text conveys the state
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(ConvertTheme.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
struct EventInspectorSheet_Previews: PreviewProvider {
    static var previews: some View {
        EventInspectorSheet()
            .environmentObject(DemoViewModel())
    }
}
#endif
