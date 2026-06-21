import ConvertSwiftSDK
import SwiftUI

/// The Features tab — evaluate features and render their typed variables
/// (Story 7.4 / DEMO-3).
///
/// Mirrors ``ExperiencesView``'s structure: a pinned header of run controls over
/// a newest-first scrolling card list (per `ux/DESIGN.md`: result screens are "a
/// header (run controls) over a newest-first scrolling card list"). The two
/// header buttons bucket the visitor — **Run Feature** resolves the single
/// baseline feature, **Run All** resolves every feature the config carries — by
/// calling ``DemoViewModel/runFeature()`` / ``DemoViewModel/runFeatures()``, each
/// of which prepends to the capped-20, newest-first
/// ``DemoViewModel/evaluatedFeatures`` buffer this screen renders.
///
/// Per UX-DR24 the buttons are **never** `.disabled(...)` — a degraded run is a
/// valid outcome the view model surfaces honestly (a `.disabled` feature card, or
/// a neutral ``DemoViewModel/featuresEmptyNote``), never a crash and never a
/// no-op, so gating the buttons would only hide the SDK's state and teach nothing.
///
/// The screen's headline behavior is the honest **absent**-variable rendition:
/// every `.enabled` feature card appends one ``FeatureVariableRow`` built from the
/// `absentType:` init for ``DemoViewModel/absentVariableKey`` — a key guaranteed
/// absent — so the card shows "here are this feature's vars, AND here's what an
/// absent one looks like" (em-dash value + neutral muted note, never an error).
///
/// The `NavigationView` + `.navigationViewStyle(.stack)` chrome, the
/// `.navigationTitle`, and the shared Event-Inspector toolbar button are preserved
/// from the Story 7.1 shell (iOS 15 floor: not `NavigationStack`).
struct FeaturesView: View {

    /// App-level state, injected once at the app root via `.environmentObject`.
    /// Owns the SDK, the feature-run methods, and the newest-first feature buffer.
    @EnvironmentObject private var viewModel: DemoViewModel

    var body: some View {
        NavigationView {
            VStack(spacing: ConvertTheme.space4) {
                runControls
                featureList
                    .frame(maxHeight: .infinity)
            }
            .padding(.top, ConvertTheme.space4)
            .navigationTitle("Features")
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
            runButton("Run Feature", accessibilityLabel: "Run Feature") {
                Task { await viewModel.runFeature() }
            }
            runButton("Run All", accessibilityLabel: "Run all features") {
                Task { await viewModel.runFeatures() }
            }
        }
        .padding(.horizontal, ConvertTheme.space4)
    }

    /// The result region below the header: the empty state when no run has happened
    /// yet, otherwise the newest-first scrolling list of feature cards.
    ///
    /// A `LazyVStack` in a `ScrollView` (not a `List`) is the right container — the
    /// cards are self-contained grouped panels, so `List`'s separators and insets
    /// would fight the card design. Card inserts are deliberately **not**
    /// animation-gated (no `withAnimation`, no `.animation` modifier): the end state
    /// renders immediately for everyone, which is the simplest Reduce-Motion-correct
    /// choice (the a11y floor forbids animation-gated inserts).
    ///
    /// `Feature` is neither `Identifiable` nor `Hashable`, and `feature.id`
    /// is `""` for a `.disabled` feature — so an `id: \.id` would COLLIDE across
    /// disabled rows and across re-runs of the same key. The `ForEach` therefore
    /// keys on the enumerated offset (index identity), exactly like the
    /// `FeatureVariableRow` preview.
    @ViewBuilder
    private var featureList: some View {
        if viewModel.evaluatedFeatures.isEmpty && viewModel.featuresEmptyNote == nil {
            EmptyStateView(
                systemImage: "bolt.fill",
                title: "No features evaluated yet",
                hint: "Evaluate a feature to see its typed variables."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: ConvertTheme.space3) {
                    // The honest degraded signal from `runFeatures()` returning `[]`:
                    // a neutral secondary note, NOT an error card and NOT an error
                    // hue (Features does not use `ResultCard`).
                    if let note = viewModel.featuresEmptyNote {
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, ConvertTheme.space2)
                    }
                    ForEach(Array(viewModel.evaluatedFeatures.enumerated()), id: \.offset) { _, feature in
                        featureCard(feature)
                    }
                }
                .padding(.horizontal, ConvertTheme.space4)
                .padding(.bottom, ConvertTheme.space4)
            }
        }
    }

    /// One grouped feature card: the key + a status chip, then one
    /// ``FeatureVariableRow`` per resolved variable (sorted by name for a
    /// deterministic order), and — on `.enabled` features only — the headline
    /// absent-variable demo row.
    ///
    /// Container styling mirrors ``ResultCard``'s grouped panel
    /// (`secondarySystemGroupedBackground` fill + `radiusMd` continuous corners,
    /// inner `space4` padding). A `.disabled` feature carries no variables, so the
    /// per-variable `ForEach` renders nothing and the absent-demo row is gated off
    /// — a disabled card is honestly just its key + "Disabled" chip (FR22).
    @ViewBuilder
    private func featureCard(_ feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: ConvertTheme.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text(feature.key)
                    .font(.headline)
                Spacer(minLength: ConvertTheme.space2)
                statusChip(for: feature.status)
            }

            // One row per variable, iterated deterministically (sorted by name) so
            // the order is stable across re-runs and across launches.
            ForEach(feature.variables.sorted(by: { $0.key < $1.key }), id: \.key) { name, variable in
                FeatureVariableRow(name: name, variable: variable)
            }

            // The headline absent-variable demo — only on `.enabled` features,
            // where it reads as "this feature has these vars, AND here's an absent
            // one". `DemoViewModel.absentVariableKey` is guaranteed absent by
            // construction (so `feature.variable(absentVariableKey, as: String.self)`
            // is always `nil`); the `absentType:` init is the honest rendition of
            // that nil — em-dash value + neutral muted note, no force-unwrap.
            if feature.status == .enabled {
                Text("Demonstrating an absent variable:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FeatureVariableRow(name: DemoViewModel.absentVariableKey, absentType: "string")
            }
        }
        .padding(ConvertTheme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: ConvertTheme.radiusMd, style: .continuous))
    }

    /// Maps a feature's status to its reused ``StatusBadge`` chip. Both styles
    /// already carry symbol + text + a fused VoiceOver state word, so color is
    /// never the only channel.
    ///
    /// - Parameter status: The resolved feature status.
    /// - Returns: A delivered (`.enabled`) or neutral-queued (`.disabled`) badge.
    @ViewBuilder
    private func statusChip(for status: FeatureStatus) -> some View {
        switch status {
        case .enabled:
            StatusBadge("Enabled", style: .delivered)
        case .disabled:
            StatusBadge("Disabled", style: .queued)
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
