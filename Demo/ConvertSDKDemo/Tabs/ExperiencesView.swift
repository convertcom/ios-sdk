import SwiftUI

/// The Experiences tab — the demo's start screen (Story 7.3 / DEMO-4).
///
/// A pinned header of run controls sits over a newest-first scrolling list of
/// result cards (per `ux/DESIGN.md`: result screens are "a header (run controls)
/// over a newest-first scrolling card list"). The two header buttons bucket the
/// visitor — **Run Experience** runs the single baseline experience, **Run All**
/// runs every experience the config carries — by calling
/// ``DemoViewModel/runExperience()`` / ``DemoViewModel/runExperiences()``, each of
/// which prepends one or more ``ResultCard/Item`` to the capped-20, newest-first
/// ``DemoViewModel/resultCards`` buffer this screen renders.
///
/// Per UX-DR24 the buttons are **never** `.disabled(...)` — not while loading, not
/// while not-ready. A not-ready tap is a valid degraded outcome the view model
/// surfaces as an actionable ``ResultCard`` (it never crashes and never no-ops), so
/// gating the buttons would only hide the SDK's state and teach nothing.
///
/// The `NavigationView` + `.navigationViewStyle(.stack)` chrome, the
/// `.navigationTitle`, and the shared `.inspectorToolbar()` button are preserved
/// from the Story 7.1 shell (iOS 15 floor: not `NavigationStack`).
struct ExperiencesView: View {

    /// App-level state, injected once at the app root via `.environmentObject`.
    /// Owns the SDK, the run methods, and the newest-first result-card buffer.
    @EnvironmentObject private var viewModel: DemoViewModel

    var body: some View {
        NavigationView {
            VStack(spacing: ConvertTheme.space4) {
                runControls
                cardList
                    .frame(maxHeight: .infinity)
            }
            .padding(.top, ConvertTheme.space4)
            .navigationTitle("Experiences")
            .inspectorToolbar()
        }
        .navigationViewStyle(.stack)
    }

    /// The pinned header: the two never-disabled, accent-tinted run buttons.
    ///
    /// Both buttons share construction through ``runButton(_:accessibilityLabel:action:)``
    /// so the `.borderedProminent` + accent-tint + 44 pt + label styling lives in one
    /// place (DRY). Each wraps its async `@MainActor` view-model call in a `Task`.
    private var runControls: some View {
        HStack(spacing: ConvertTheme.space3) {
            runButton("Run Experience", accessibilityLabel: "Run Experience") {
                Task { await viewModel.runExperience() }
            }
            runButton("Run All", accessibilityLabel: "Run all experiences") {
                Task { await viewModel.runExperiences() }
            }
        }
        .padding(.horizontal, ConvertTheme.space4)
    }

    /// The result region below the header: the empty state when no run has happened
    /// yet, otherwise the newest-first scrolling list of cards.
    ///
    /// A `LazyVStack` in a `ScrollView` (not a `List`) is the right container — the
    /// cards are self-contained grouped panels, so `List`'s separators and insets
    /// would fight the card design. Card inserts are deliberately **not**
    /// animation-gated (no `withAnimation`, no `.animation` modifier): the end state
    /// renders immediately for everyone, which is the simplest Reduce-Motion-correct
    /// choice (the a11y floor forbids animation-gated inserts).
    @ViewBuilder
    private var cardList: some View {
        if viewModel.resultCards.isEmpty {
            EmptyStateView(
                systemImage: "testtube.2",
                title: "No experiences run yet",
                hint: "Tap Run to bucket the visitor into an experience."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: ConvertTheme.space3) {
                    ForEach(viewModel.resultCards) { item in
                        ResultCard(item)
                    }
                }
                .padding(.horizontal, ConvertTheme.space4)
                .padding(.bottom, ConvertTheme.space4)
            }
        }
    }

    /// Builds one run-control button with the shared styling contract.
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
    private func runButton(
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
