import SwiftUI

/// A compact status strip that announces the device's current connectivity state
/// (Story 7.6 / DEMO-6 `offline-banner`).
///
/// The banner is intentionally small and declarative: it maps a single `Bool`
/// (`isOnline`) to a symbol + text label pair so connectivity state is
/// immediately visible at the top of the Config screen (and any other screen
/// that embeds it). Color is a redundant signal, never the only signal — the
/// text label "Online" / "Offline" always appears beside the symbol so meaning
/// survives grayscale and color blindness (DESIGN.md hard rule).
///
/// **Idiom:** the symbol-name / accent-color / label mapping lives in the
/// private `Appearance` computed property in ONE place — mirroring
/// ``StatusBadge.Style``'s enum — so the symbol/color/text never drift apart
/// when the `isOnline` condition is evaluated.
///
/// **A11y rule:** the banner collapses to one `accessibilityElement` whose
/// fused `.accessibilityLabel` is "Online" or "Offline". The symbol is purely
/// decorative (`.accessibilityHidden(true)`); the label carries the state word.
struct OfflineBanner: View {

    /// Internal type that bundles the three presentation values for one
    /// connectivity state: the SF Symbol name, the accent color (used only on
    /// the symbol, a UI element ≥3:1 — never on the text), and the visible
    /// text label. Defined as a struct rather than a free tuple so each field is
    /// named and the `appearance` property reads clearly.
    ///
    /// Both symbol names (`wifi`, `wifi.slash`) are present on iOS 15.
    private struct Appearance {
        /// SF Symbol name for the connectivity icon.
        let symbolName: String
        /// Hue applied to the symbol (UI-element color, ≥3:1 contrast).
        /// The text label is always a system label color — never this hue.
        let symbolColor: Color
        /// The always-visible text label beside the symbol.
        let label: String
    }

    /// Whether the device currently has a usable network path (per
    /// `NWPathMonitor`; `path.status == .satisfied`).
    private let isOnline: Bool

    /// - Parameter isOnline: `true` when the device has a usable network path.
    init(isOnline: Bool) {
        self.isOnline = isOnline
    }

    /// The single computed mapping: symbol name + accent color + label text, all
    /// resolved from `isOnline` in ONE place so they never drift apart.
    private var appearance: Appearance {
        if isOnline {
            return Appearance(
                symbolName: "wifi",
                symbolColor: ConvertTheme.success,
                label: "Online"
            )
        } else {
            return Appearance(
                symbolName: "wifi.slash",
                symbolColor: ConvertTheme.error,
                label: "Offline"
            )
        }
    }

    var body: some View {
        HStack(spacing: ConvertTheme.space2) {
            Image(systemName: appearance.symbolName)
                // Symbol carries the hue (UI element ≥3:1) — meaning is also
                // in the text label, so the symbol itself is decorative here.
                .foregroundStyle(appearance.symbolColor)
                .accessibilityHidden(true)

            Text(appearance.label)
                // Text stays a system label color — the symbol carries the hue,
                // the text carries the meaning (DESIGN.md hard rule).
                .foregroundStyle(.primary)
                .font(.subheadline)
        }
        .padding(.horizontal, ConvertTheme.space3)
        .padding(.vertical, ConvertTheme.space2)
        // Subtle system fill so the banner reads as a grouped element without
        // putting text on a saturated background.
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: ConvertTheme.radiusSm, style: .continuous))
        // Fuse to one VoiceOver element: the symbol is decorative, the text
        // label word is the only thing VoiceOver announces.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOnline ? "Online" : "Offline")
    }
}

// MARK: - Preview

#if DEBUG
struct OfflineBanner_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: ConvertTheme.space3) {
            OfflineBanner(isOnline: true)
            OfflineBanner(isOnline: false)
        }
        .padding(ConvertTheme.space5)
        .background(Color(.systemGroupedBackground))
        .previewLayout(.sizeThatFits)
        .previewDisplayName("Online + Offline")
    }
}
#endif
