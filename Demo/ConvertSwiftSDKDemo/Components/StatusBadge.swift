import SwiftUI

/// The Convert status chip — the single reusable accessibility primitive every
/// Epic-7 screen reuses for lifecycle / level indicators (delivered, queued,
/// WARN, ERROR, INFO/DEBUG).
///
/// The hard rule from `ux/DESIGN.md` and the EXPERIENCE.md Accessibility Floor:
/// **color never carries meaning alone.** Every badge pairs four redundant
/// channels — a soft fill, a darkened `*-text` label color, a per-state SF
/// Symbol, and a text label — so the state survives grayscale, color blindness,
/// and VoiceOver. It is never a saturated fill with white text, and never color
/// on its own. The combined VoiceOver label (e.g. "bucketing, delivered")
/// carries the state word so meaning reaches non-visual users intact.
struct StatusBadge: View {

    /// State → (SF Symbol, soft-fill, label/symbol color, VoiceOver word).
    ///
    /// The mapping lives here in ONE place so every screen that renders a chip
    /// shares an identical symbol/color/word per state. All five symbols are
    /// verified present on iOS 15. The two neutral states (`queued`, `info`)
    /// use system colors (`secondarySystemFill` / `secondaryLabel`) which
    /// auto-adapt light/dark, matching DEMO-4's decision not to mint brand
    /// assets for them.
    enum Style {
        /// Delivered / on / success.
        case delivered
        /// Queued / off / dedup / neutral.
        case queued
        /// WARN level.
        case warn
        /// ERROR / failed.
        case error
        /// INFO / DEBUG level.
        case info

        /// SF Symbol that rides alongside the text (decorative, but always present).
        var symbolName: String {
            switch self {
            case .delivered: return "checkmark.circle"
            case .queued: return "clock"
            case .warn: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            case .info: return "info.circle"
            }
        }

        /// Soft capsule fill behind the label — never a saturated fill.
        var fillColor: Color {
            switch self {
            case .delivered: return ConvertTheme.successSoft
            case .queued: return Color(.secondarySystemFill)
            case .warn: return ConvertTheme.warnSoft
            case .error: return ConvertTheme.errorSoft
            case .info: return Color(.secondarySystemFill)
            }
        }

        /// Darkened label + symbol color (AA on the soft fill) — never white.
        var foregroundColor: Color {
            switch self {
            case .delivered: return ConvertTheme.successText
            case .queued: return Color(.secondaryLabel)
            case .warn: return ConvertTheme.warnText
            case .error: return ConvertTheme.errorText
            case .info: return Color(.secondaryLabel)
            }
        }

        /// State word appended to the VoiceOver label so meaning never relies on
        /// color — e.g. `.delivered` reads "…, delivered".
        var accessibilityWord: String {
            switch self {
            case .delivered: return "delivered"
            case .queued: return "queued"
            case .warn: return "warning"
            case .error: return "error"
            case .info: return "info"
            }
        }
    }

    /// Text that rides alongside the symbol — e.g. "Delivered", "WARN", "[ERROR]".
    private let text: String

    /// State that drives the symbol, color pair, and VoiceOver word.
    private let style: Style

    /// - Parameters:
    ///   - text: The visible label beside the symbol.
    ///   - style: The state driving symbol, colors, and the VoiceOver word.
    init(_ text: String, style: Style) {
        self.text = text
        self.style = style
    }

    var body: some View {
        HStack(spacing: ConvertTheme.space1) {
            Image(systemName: style.symbolName)
                // The combined accessibility label below already names the state,
                // so the symbol must not be announced separately.
                .accessibilityHidden(true)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(style.foregroundColor)
        .padding(.horizontal, ConvertTheme.space2)
        .padding(.vertical, ConvertTheme.space1 / 2)
        .background(style.fillColor)
        // `radiusFull` capsule — a `Capsule()` clip is the full-radius pill.
        .clipShape(Capsule())
        // Expose one static element whose label fuses text + state word, so the
        // meaning survives without color (e.g. "bucketing, delivered").
        // NOTE: this chip is a non-interactive indicator, so no 44pt minimum is
        // forced here. Any INTERACTIVE use (wrapping it in a Button / tappable
        // row) MUST meet the 44pt tap-target floor per EXPERIENCE.md.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(text), \(style.accessibilityWord)")
    }
}

#if DEBUG
struct StatusBadge_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: ConvertTheme.space3) {
            StatusBadge("Delivered", style: .delivered)
            StatusBadge("Queued", style: .queued)
            StatusBadge("WARN", style: .warn)
            StatusBadge("[ERROR]", style: .error)
            StatusBadge("INFO", style: .info)
        }
        .padding(ConvertTheme.space5)
        .previewLayout(.sizeThatFits)
    }
}
#endif
