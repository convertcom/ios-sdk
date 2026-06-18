import SwiftUI

/// The Conversions tab — track a goal and render the outcome cards (Story 7.5 /
/// DEMO-3).
///
/// Fills the Story 7.1 shell (which was an `EmptyStateView` only): a pinned header
/// of never-disabled track controls over a newest-first scrolling card list (per
/// `ux/DESIGN.md`: result screens are "a header (run controls) over a newest-first
/// scrolling card list"). The two header buttons drive
/// ``DemoViewModel/trackGoal()`` / ``DemoViewModel/trackUnknownGoal()``, each of
/// which prepends to the capped, newest-first ``DemoViewModel/conversionCards``
/// buffer this screen renders.
///
/// The screen's headline behavior is honesty about two outcomes the SDK can't
/// surface itself: a **goal-not-found** attempt (Track Unknown Goal drives a red
/// ``ResultCard`` `.error`, because `trackConversion` is non-throwing and drops an
/// unknown goal silently) and a **dedup** of a repeat conversion (a neutral
/// `.dedup` card — no second conversion event). Both are valid outcomes the view
/// model surfaces as cards, never a crash and never a silent no-op.
///
/// Per UX-DR24 the buttons are **never** `.disabled(...)` — a degraded track is a
/// valid, honestly-rendered outcome, so gating the buttons would only hide the
/// SDK's state and teach nothing.
///
/// The `NavigationView` + `.navigationViewStyle(.stack)` chrome, the
/// `.navigationTitle`, and the shared Event-Inspector toolbar button are preserved
/// from the Story 7.1 shell (iOS 15 floor: not `NavigationStack`).
struct ConversionsView: View {

    /// App-level state, injected once at the app root via `.environmentObject`.
    /// Owns the SDK, the goal-tracking methods, and the newest-first conversion buffer.
    @EnvironmentObject private var viewModel: DemoViewModel

    var body: some View {
        NavigationView {
            VStack(spacing: ConvertTheme.space4) {
                trackControls
                conversionList
                    .frame(maxHeight: .infinity)
            }
            .padding(.top, ConvertTheme.space4)
            .navigationTitle("Conversions")
            .inspectorToolbar()
        }
        .navigationViewStyle(.stack)
    }

    /// The pinned header: the two never-disabled, accent-tinted track buttons.
    ///
    /// Both buttons share construction through ``trackButton(_:accessibilityLabel:action:)``
    /// so the `.borderedProminent` + accent-tint + 44 pt + label styling lives in one
    /// place (DRY). Each wraps its async `@MainActor` view-model call in a `Task`.
    private var trackControls: some View {
        HStack(spacing: ConvertTheme.space3) {
            trackButton("Track Goal", accessibilityLabel: "Track the goal") {
                Task { await viewModel.trackGoal() }
            }
            trackButton("Track Unknown Goal", accessibilityLabel: "Track an unknown goal") {
                Task { await viewModel.trackUnknownGoal() }
            }
        }
        .padding(.horizontal, ConvertTheme.space4)
    }

    /// The result region below the header: the empty state when nothing has been
    /// tracked yet, otherwise the newest-first scrolling list of result cards.
    ///
    /// A `LazyVStack` in a `ScrollView` (not a `List`) is the right container — the
    /// cards are self-contained grouped panels, so `List`'s separators and insets
    /// would fight the card design. Card inserts are deliberately **not**
    /// animation-gated (no `withAnimation`, no `.animation` modifier): the end state
    /// renders immediately for everyone, which is the simplest Reduce-Motion-correct
    /// choice (the a11y floor forbids animation-gated inserts).
    ///
    /// `ResultCard.Item` IS `Identifiable`, but the `ForEach` keys on the enumerated
    /// offset (index identity) to mirror ``FeaturesView`` — repeat / dedup rows can
    /// share content, so offset keying stays stable across re-tracks of the same goal.
    @ViewBuilder
    private var conversionList: some View {
        if viewModel.conversionCards.isEmpty {
            EmptyStateView(
                systemImage: "dollarsign.circle",
                title: "No conversions tracked yet",
                hint: "Track a goal to see success / dedup results."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: ConvertTheme.space3) {
                    ForEach(Array(viewModel.conversionCards.enumerated()), id: \.offset) { _, card in
                        ResultCard(card)
                    }
                }
                .padding(.horizontal, ConvertTheme.space4)
                .padding(.bottom, ConvertTheme.space4)
            }
        }
    }

    /// Builds one track-control button with the shared styling contract.
    ///
    /// `.borderedProminent` + an explicit `.tint(ConvertTheme.accent)` (the TabView
    /// root already tints app-wide; this restates it for clarity per the story) +
    /// `.frame(minHeight: 44)` to guarantee the ≥ 44 pt tap target (UX-DR4), and an
    /// explicit VoiceOver label naming the action's intent. The button is **never**
    /// `.disabled(...)` (UX-DR24) — that contract is enforced by omission here.
    ///
    /// - Parameters:
    ///   - title: The visible button text.
    ///   - accessibilityLabel: The VoiceOver label (role + intent).
    ///   - action: The tap handler (each caller wraps its async call in a `Task`).
    private func trackButton(
        _ title: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(ConvertTheme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityLabel(accessibilityLabel)
    }
}
