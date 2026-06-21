import SwiftUI
import UIKit

/// The Config tab — the SDK's three-branch readiness machine made legible, plus
/// the reliable QA reset-visitor affordance (Story 7.6 / DEMO-6).
///
/// Fills the Story 7.1 shell (which was an `EmptyStateView` only). The screen is
/// the live demonstration of the SDK's failure-detection pattern: because the
/// `SystemEvents` set is frozen (no typed error event — FR52), the SDK's
/// failures are otherwise *silent*, so this screen renders the three states the
/// ``DemoViewModel/start()`` driver lands — Loading / Loaded / Failed — and
/// announces each one to VoiceOver so a blind developer can tell a load in
/// progress from a hang (AC2/AC3).
///
/// **Failure-detection scope (the descope this story ships under):** the
/// ``ConfigState/failed(reason:)`` branch is reached by the **two fully-public
/// triggers only** — a thrown `ConvertError` from `ready()` and the 10 s
/// readiness timeout (both in ``DemoViewModel/start()``). The third trigger the
/// pattern teaches — a *WARN/ERROR log before the first `READY`* — is **deferred
/// to Story 7.2b**: the SDK exposes no public log-observation seam yet (the only
/// logger-accepting init is `internal`; the default is `NoopLogger`), so there
/// is nothing to observe. This screen therefore detects failure via timeout +
/// thrown error, never a pre-READY WARN log.
///
/// The `NavigationView` + `.navigationViewStyle(.stack)` chrome, the
/// `.navigationTitle`, and the shared Event-Inspector toolbar button are
/// preserved from the Story 7.1 shell (iOS 15 floor: not `NavigationStack`).
struct ConfigView: View {

    /// App-level state, injected once at the app root via `.environmentObject`.
    /// Owns the SDK, the ``DemoViewModel/configState`` machine, the config-panel
    /// data, and the reset-visitor affordance.
    @EnvironmentObject private var viewModel: DemoViewModel

    /// The fixed, actionable hint shown on a config failure (AC2/AC3 / Task 1.3).
    ///
    /// Declared once here so the `.failed` ``ResultCard`` and the VoiceOver
    /// announcement read the SAME string — the hint can never drift between the
    /// two surfaces that both must show it ("reason + the fixed hint" / "post
    /// 'configuration failed: <reason>. <hint>'").
    private static let failureHint = "Check network + SDK key"

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: ConvertTheme.space4) {
                    configStateBody
                    resetSection
                }
                .padding(ConvertTheme.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Config")
            .inspectorToolbar()
            // Post a VoiceOver announcement whenever the state machine CHANGES, so
            // a non-visual user hears Loading / Loaded / Failed without navigating
            // to the affected element (AC3 / Task 2.4). `ConfigState` is `Equatable`,
            // so `.onChange(of:)` fires once per real transition. The UIKit
            // `UIAccessibility.post` is the iOS-15-safe path (SwiftUI's
            // `AccessibilityNotification.Announcement` is iOS 17+) and keeps the view
            // model free of UIKit — the announcement is composed and posted here in
            // the View layer, mirroring `EventInspectorSheet`'s "delivered" post.
            .onChange(of: viewModel.configState) { newState in
                UIAccessibility.post(
                    notification: .announcement,
                    argument: Self.announcement(for: newState)
                )
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Config state machine (AC2 / AC3)

    /// Renders the active branch of the ``ConfigState`` machine.
    ///
    /// The three cases mirror ``DemoViewModel/start()``'s terminal states exactly:
    /// `.loading` shows a spinner that announces itself as busy to VoiceOver (so it
    /// is distinguishable from a hang); `.loaded` shows the populated
    /// ``ConfigInfoPanel`` plus a fetched-time caption; `.failed` reuses
    /// ``ResultCard`` `.error` (the honest reuse — it already carries the fused
    /// VoiceOver label and the message + hint layout) with the fixed hint.
    @ViewBuilder
    private var configStateBody: some View {
        switch viewModel.configState {
        case .loading:
            loadingState
        case .loaded(let fetchedAt):
            loadedState(fetchedAt: fetchedAt)
        case .failed(let reason):
            // `.failed` is reached only by the timeout or a thrown `ConvertError`
            // (see the type doc-comment) — NOT by a pre-READY WARN log, which is
            // deferred to Story 7.2b for lack of a public log seam.
            ResultCard(
                ResultCard.Item(
                    title: "Configuration failed",
                    detail: reason,
                    hint: Self.failureHint,
                    variant: .error
                )
            )
        }
    }

    /// The Loading branch: a spinner labelled for sighted users, and — critically —
    /// posting an accessibility-busy "Loading configuration" to VoiceOver.
    ///
    /// On the iOS 15 floor there is no `ContentUnavailableView`, so the busy state
    /// is conveyed by fusing the spinner + label into one accessibility element with
    /// an explicit label and the `.updatesFrequently` trait — the iOS-15 way to tell
    /// a blind developer "this is working, not hung" (AC3 / Task 2.4). The
    /// `.onChange` announcement above complements this for the transition INTO
    /// loading; this element keeps the busy state legible while it lingers.
    private var loadingState: some View {
        HStack(spacing: ConvertTheme.space3) {
            ProgressView()
            Text("Loading configuration…")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, ConvertTheme.space5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading configuration")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The Loaded branch: the populated ``ConfigInfoPanel``, a small caption stamping
    /// when the config resolved, and a live ``trackingToggle`` that calls
    /// ``DemoViewModel/setTracking(_:)`` (Story 5.6).
    ///
    /// The caption is formatted with a `DateFormatter` (short date + short time) —
    /// NOT the iOS-15-fragile `Date.FormatStyle`/`.formatted(...)` — to stay safely
    /// on the deployment floor (constraint: `DateFormatter` is the safe formatter).
    /// The panel already owns its own per-row VoiceOver labels; the caption and toggle
    /// are plain elements VoiceOver reads in reading order.
    private func loadedState(fetchedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: ConvertTheme.space2) {
            ConfigInfoPanel(viewModel.configPanelData)
            Text("Loaded \(Self.fetchedAtFormatter.string(from: fetchedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
            trackingToggle
        }
    }

    /// A live `Toggle` that gates SDK-level event delivery at runtime (Story 5.6).
    ///
    /// Bound to the published ``DemoViewModel/isRuntimeTrackingEnabled``. Each flip
    /// dispatches a `Task` that calls the `@MainActor`-inherited ``DemoViewModel/setTracking(_:)``
    /// — which awaits ``ConvertSwiftSDK/setTrackingEnabled(_:)`` then confirms the new state via
    /// ``ConvertSwiftSDK/isTrackingEnabled()``.  Because ``DemoViewModel`` is `@MainActor` and the
    /// toggle's binding write is already on the main actor, no additional `@MainActor` annotation
    /// is needed on the `Task` closure.
    ///
    /// The fused VoiceOver label reads "Tracking enabled, toggle" (role appended by SwiftUI)
    /// and the value reads "on"/"off" — consistent with the ``ConfigInfoPanel`` Tracking row's
    /// "Tracking, On/Off" pattern. A ≥ 44 pt tap target is honoured via `.frame(minHeight: 44)`.
    private var trackingToggle: some View {
        Toggle(isOn: Binding(
            get: { viewModel.isRuntimeTrackingEnabled },
            set: { enabled in
                Task {
                    await viewModel.setTracking(enabled)
                }
            }
        )) {
            Text("Tracking enabled")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
        .accessibilityLabel("Tracking enabled")
    }

    // MARK: - Reset-visitor affordance (AC4)

    /// The reset-visitor section: the never-disabled Reset button, the post-reset
    /// confirmation, and the "reinstall is not a guaranteed reset" caveat copy.
    ///
    /// The control is always present and always enabled (UX-DR24 — a degraded state
    /// is rendered, never gated away). Tapping it calls the synchronous
    /// `@MainActor` ``DemoViewModel/resetVisitor()`` directly (no `Task` wrapper
    /// needed — it does not suspend). After a reset, ``DemoViewModel/lastResetVisitorMasked``
    /// becomes non-`nil` and the masked-id confirmation appears.
    private var resetSection: some View {
        VStack(alignment: .leading, spacing: ConvertTheme.space2) {
            actionButton("Reset Visitor", accessibilityLabel: "Reset visitor") {
                viewModel.resetVisitor()
            }

            if let masked = viewModel.lastResetVisitorMasked {
                // The new visitor id is shown MASKED (PII-safe, NFR6) — the view
                // model never hands the full UUID to the UI. Fused into one element
                // so VoiceOver reads the confirmation as a single sentence.
                Text("New visitor: \(masked) — bucketing reset")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("New visitor \(masked), bucketing reset")
            }

            // Reinstall is NOT a guaranteed reset (AC4.4 / Task 4.4): Keychain
            // reinstall-continuity is best-effort (R7), so a reinstalled app may keep
            // the same visitor UUID and the same sticky bucketing. The reliable path
            // is this affordance — state that plainly in secondary caption text.
            Text(
                "Reinstalling the app is not a guaranteed reset "
                + "(Keychain continuity is best-effort). Use Reset Visitor "
                + "for a reliable fresh visitor."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, ConvertTheme.space2)
    }

    /// Builds an action button with the shared styling contract — the same contract
    /// `ConversionsView`'s `trackButton` enforces, kept consistent across screens.
    ///
    /// `.borderedProminent` + an explicit `.tint(ConvertTheme.accent)` + a
    /// `.frame(minHeight: 44)` guaranteeing the ≥ 44 pt tap target (UX-DR4), plus an
    /// explicit VoiceOver label. The button is **never** `.disabled(...)` (UX-DR24)
    /// — enforced by omission here.
    ///
    /// - Parameters:
    ///   - title: The visible button text.
    ///   - accessibilityLabel: The VoiceOver label (role + intent).
    ///   - action: The tap handler.
    private func actionButton(
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

    // MARK: - Formatting & announcements

    /// Formats the Loaded "fetched at" stamp with a `DateFormatter` (short date +
    /// short time) — the iOS-15-safe formatter (NOT `Date.FormatStyle`). A single
    /// `static let` so the formatter is built once, not per render.
    private static let fetchedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// Maps a ``ConfigState`` to the VoiceOver announcement string posted on a
    /// transition into it (AC3 / Task 2.4). Kept beside ``failureHint`` so the
    /// `.failed` announcement and the `.failed` card share the exact hint:
    /// - `.loading` → "Loading configuration";
    /// - `.loaded`  → "Configuration loaded";
    /// - `.failed`  → "configuration failed: <reason>. Check network + SDK key"
    ///   (the exact shape from the story's AC3 / Task 2.4).
    ///
    /// `<reason>` is NOT assumed to carry trailing punctuation, but the real reasons do — the
    /// timeout message ("Configuration fetch timed out.") and `ConvertError` descriptions both
    /// end in ".". A single trailing sentence-ending char ('.', '!', '?') is stripped from
    /// `reason` before interpolation so exactly ONE period separates the reason from the hint
    /// (otherwise "…timed out.. Check…" would double up).
    private static func announcement(for state: ConfigState) -> String {
        switch state {
        case .loading:
            return "Loading configuration"
        case .loaded:
            return "Configuration loaded"
        case .failed(let reason):
            let trimmedReason = [".", "!", "?"].contains(String(reason.suffix(1)))
                ? String(reason.dropLast()) : reason
            return "configuration failed: \(trimmedReason). \(failureHint)"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ConfigView_Previews: PreviewProvider {
    static var previews: some View {
        ConfigView()
            .environmentObject(DemoViewModel())
    }
}
#endif
