import SwiftUI

/// The Offline tab — the live connectivity banner over the SDK's headline
/// suspension → termination → recovery narrative (Story 7.6 / DEMO-6, AC1).
///
/// Fills the Story 7.1 shell (which was an `EmptyStateView` only). This is the
/// SDK's headline differentiator made legible: cached config serves offline,
/// bucketing stays deterministic, events persist to an on-disk queue, and the
/// background `URLSession` upload survives suspension and termination — so events
/// arrive even after the app is gone. The screen shows the consumer-visible half
/// (the live banner + the narrative) and points the reader at the Event Inspector
/// toolbar button, where the headline beat actually plays out: queued events flip
/// to delivered once connectivity returns.
///
/// This is a read-only narrative screen, so it carries no run controls of its own
/// — only the live ``OfflineBanner`` and the static narrative text. The developer
/// drives the banner by toggling airplane mode; `NWPathMonitor` flips
/// ``DemoViewModel/isOnline`` and the banner re-renders.
///
/// The `NavigationView` + `.navigationViewStyle(.stack)` chrome, the
/// `.navigationTitle`, and the shared Event-Inspector toolbar button are
/// preserved from the Story 7.1 shell (iOS 15 floor: not `NavigationStack`).
struct OfflineView: View {

    /// App-level state, injected once at the app root via `.environmentObject`.
    /// Supplies the observed ``DemoViewModel/isOnline`` connectivity flag the
    /// banner renders.
    @EnvironmentObject private var viewModel: DemoViewModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: ConvertTheme.space4) {
                    // The live banner, pinned near the top. It auto-updates as
                    // `NWPathMonitor` flips `isOnline`, and carries its own fused
                    // "Online" / "Offline" VoiceOver label (symbol + text, never
                    // color-only) so the state survives grayscale and VoiceOver.
                    OfflineBanner(isOnline: viewModel.isOnline)

                    paragraph(
                        "Offline, the SDK keeps working. The last-fetched "
                        + "configuration serves from cache and bucketing stays "
                        + "deterministic — the same visitor lands in the same "
                        + "variation, with or without a network."
                    )

                    paragraph(
                        "Conversions and other events you track offline are "
                        + "persisted to an on-disk queue, not held only in memory. "
                        + "When the app backgrounds, the queue is handed to a "
                        + "background URLSession upload that the system delivers "
                        + "independently of the app — so the upload survives the "
                        + "app being suspended and even terminated under memory "
                        + "pressure."
                    )

                    paragraph(
                        "Once connectivity returns, queued events flip to "
                        + "delivered in the Event Inspector. Open it from the "
                        + "toolbar button (top-right) and watch the lifecycle "
                        + "badges change from Queued to Delivered — that is the "
                        + "headline offline-delivery beat."
                    )

                    // The one true data-loss edge, narrated honestly (Task 3.4):
                    // never overclaim guaranteed delivery through a user force-quit.
                    paragraph(
                        "Honest edge: a force-quit cancels the in-flight upload, "
                        + "but the persisted events stay on disk and drain on the "
                        + "next launch. The only bounded loss is a corrupted "
                        + "on-disk queue, which is discarded and re-initialized "
                        + "(and logged) — never a crash, and never a silent claim "
                        + "of guaranteed delivery through a force-quit."
                    )
                }
                .padding(ConvertTheme.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Offline")
            .inspectorToolbar()
        }
        .navigationViewStyle(.stack)
    }

    /// Builds one narrative paragraph with the shared text contract — system
    /// `.body` in the primary label color, full-width leading-aligned, and
    /// `.fixedSize(horizontal: false, vertical: true)` so the text WRAPS and grows
    /// vertically rather than truncating at large Dynamic Type (DESIGN.md: text
    /// wraps, never truncates). A single builder keeps the four paragraphs from
    /// repeating the same modifier stack (DRY / copy-paste-detector discipline).
    ///
    /// The paragraphs are plain static text, so VoiceOver exposes each as readable
    /// text in reading order; no extra accessibility wiring is needed.
    ///
    /// - Parameter text: The paragraph copy.
    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Preview

#if DEBUG
struct OfflineView_Previews: PreviewProvider {
    static var previews: some View {
        OfflineView()
            .environmentObject(DemoViewModel())
    }
}
#endif
