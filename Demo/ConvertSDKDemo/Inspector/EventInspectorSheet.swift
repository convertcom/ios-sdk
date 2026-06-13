import SwiftUI

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
    /// control as a whole; SwiftUI's segmented `Picker` already announces the
    /// selected option, so the later a11y task (AC4) builds on this without
    /// re-plumbing the announcement.
    private var segmentPicker: some View {
        Picker("Inspector segment", selection: $viewModel.selectedSegment) {
            ForEach(DemoViewModel.InspectorSegment.allCases) { segment in
                Text(segment.title).tag(segment)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Inspector segment")
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
/// renders no mono line. The name `Text` and the `StatusBadge` stay separate
/// accessibility elements, so VoiceOver reads the name then the badge's own fused
/// label (e.g. "bucketing" then "Delivered, delivered") — the lifecycle word is
/// always reachable without color. The deeper focus / announcement behavior is the
/// later a11y task (AC4); this row only secures the basics.
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
