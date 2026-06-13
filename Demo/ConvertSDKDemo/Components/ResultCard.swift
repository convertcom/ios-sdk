import SwiftUI

/// The shared variation-result card for the demo's Experiences screen (Story 7.3).
///
/// One card reports the outcome of bucketing a single experience: a success card
/// names the variation the visitor landed in; an error card states why no
/// variation was returned plus an actionable hint. The card is a grouped panel —
/// a leading colored rule + a soft chip carry the variant's semantic hue, while
/// **all card text stays a system label color** (per `ux/DESIGN.md`
/// `components.result-card`: brand hues are used only as the rule and the chip,
/// never as body text).
///
/// **Reuse note (Story 7.5 — Conversions):** this card is reused verbatim by the
/// Conversions screen, which adds a third `dedup` outcome. The variant is modeled
/// as an OPEN enum (`Variant`) whose per-case computed properties — mirroring
/// `StatusBadge.Style` — own every visual difference. Story 7.5 adds the dedup
/// state by adding ONE enum case (`.dedup`) and its mappings; `ResultCard`'s
/// `body` does not change. See `Variant` for the exact extension point.
struct ResultCard: View {

    /// Semantic outcome of a bucketing attempt → (leading-rule color, chip fill,
    /// chip text color, SF Symbol, chip label, VoiceOver word).
    ///
    /// The mapping lives here in ONE place — exactly like `StatusBadge.Style` —
    /// so the rule, chip, and accessibility word for a given outcome are defined
    /// once and the card body reads them generically. Both symbols (`checkmark.circle`,
    /// `exclamationmark.triangle`) are verified present on iOS 15 (they are the
    /// same symbols `StatusBadge` uses for `.delivered` / `.warn`).
    ///
    /// **Story 7.5 extension point:** add `case dedup` here plus its five mapping
    /// entries — leading rule + chip on system neutrals (`secondaryLabel` chip
    /// text on a `secondarySystemFill` fill), SF Symbol `arrow.uturn.left`, chip
    /// label "Deduped", VoiceOver word "deduplicated". No change to `ResultCard`
    /// is required because the body never switches on the variant directly.
    enum Variant {
        /// A variation was returned — the visitor is bucketed into an experience.
        case success
        /// No variation was returned — config still loading, ineligible visitor,
        /// or a misconfigured experience.
        case error

        /// Thin leading rule down the card's leading edge — a UI-element hue (>=3:1),
        /// never used as body text.
        var ruleColor: Color {
            switch self {
            case .success: return ConvertTheme.success
            case .error: return ConvertTheme.error
            }
        }

        /// Soft capsule fill behind the chip label — never a saturated fill.
        var chipFillColor: Color {
            switch self {
            case .success: return ConvertTheme.successSoft
            case .error: return ConvertTheme.errorSoft
            }
        }

        /// Darkened chip label + symbol color (AA on the soft fill) — never white.
        var chipTextColor: Color {
            switch self {
            case .success: return ConvertTheme.successText
            case .error: return ConvertTheme.errorText
            }
        }

        /// SF Symbol inside the chip (decorative — hidden from VoiceOver, the
        /// fused card label below carries the meaning).
        var chipSymbolName: String {
            switch self {
            case .success: return "checkmark.circle"
            case .error: return "exclamationmark.triangle"
            }
        }

        /// Short word rendered in the chip beside the symbol.
        var chipLabel: String {
            switch self {
            case .success: return "Success"
            case .error: return "Error"
            }
        }

        /// Outcome word that opens the card's fused VoiceOver label so meaning
        /// never relies on color — e.g. `.error` reads "Error: …".
        var accessibilityWord: String {
            switch self {
            case .success: return "success"
            case .error: return "error"
            }
        }
    }

    /// A single result row the Experiences screen renders. The `DemoViewModel`
    /// (a separate task) builds one `Item` per bucketed experience; the list
    /// `ForEach`es over them, so `Item` is `Identifiable`. It is also `Equatable`
    /// so SwiftUI can diff the list cheaply.
    ///
    /// Story 7.5 builds dedup rows from this same shape (a `.dedup` variant, the
    /// experience key as `title`, and a deduplication detail string) — no new
    /// fields are needed.
    struct Item: Identifiable, Equatable {
        /// Stable identity for `ForEach`.
        let id: UUID
        /// The card's heading — the experience key, or a short fallback label
        /// (e.g. "No variation") for an error with no known key.
        let title: String
        /// The Live-Logs-vocabulary detail line. For `.success` this is rendered
        /// with `variationKey` split out as a mono segment; for `.error` it is
        /// the whole message rendered as system-label body text.
        let detail: String
        /// For `.success` only: the variation key, rendered in SF Mono inside the
        /// detail line. `nil` for error rows (whose detail is a plain message).
        let variationKey: String?
        /// For `.error` only: an actionable hint shown under the message in a
        /// secondary, smaller style. `nil` when there is no hint.
        let hint: String?
        /// Drives the leading rule, chip, and VoiceOver word.
        let variant: Variant

        /// - Parameters:
        ///   - id: Stable identity (defaults to a fresh `UUID`).
        ///   - title: The heading — experience key or a short fallback.
        ///   - detail: The Live-Logs-vocabulary detail line.
        ///   - variationKey: Success-only mono variation key; `nil` otherwise.
        ///   - hint: Error-only actionable hint; `nil` otherwise.
        ///   - variant: The outcome driving rule/chip/VoiceOver.
        init(
            id: UUID = UUID(),
            title: String,
            detail: String,
            variationKey: String? = nil,
            hint: String? = nil,
            variant: Variant
        ) {
            self.id = id
            self.title = title
            self.detail = detail
            self.variationKey = variationKey
            self.hint = hint
            self.variant = variant
        }
    }

    /// The result this card renders.
    private let item: Item

    /// - Parameter item: The bucketing outcome to display.
    init(_ item: Item) {
        self.item = item
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Leading vertical rule — a thin colored bar carrying the variant hue.
            Rectangle()
                .fill(item.variant.ruleColor)
                .frame(width: ConvertTheme.space1)

            VStack(alignment: .leading, spacing: ConvertTheme.space2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.headline)
                    Spacer(minLength: ConvertTheme.space2)
                    chip
                }

                detailLine

                if let hint = item.hint {
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(ConvertTheme.space4)
        }
        // Card text is always a system label color; the rule + chip carry the hue.
        .foregroundStyle(.primary)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: ConvertTheme.radiusMd, style: .continuous))
        // Fuse the whole card into ONE VoiceOver element whose label leads with
        // the outcome word, so meaning survives without color
        // (success → "Variation <key> for <experienceKey>"; error → "Error: <message>").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The soft-fill chip — the same four-channel pattern as `StatusBadge`
    /// (soft fill + darkened `*-text` label + SF Symbol + word), built inline so
    /// the chip's symbol/fill/label all flow from `Variant` and the variant model
    /// stays the single source of truth.
    private var chip: some View {
        HStack(spacing: ConvertTheme.space1) {
            Image(systemName: item.variant.chipSymbolName)
                // The fused card label already names the outcome; never announce
                // the decorative symbol separately.
                .accessibilityHidden(true)
            Text(item.variant.chipLabel)
        }
        .font(.caption)
        .foregroundStyle(item.variant.chipTextColor)
        .padding(.horizontal, ConvertTheme.space2)
        .padding(.vertical, ConvertTheme.space1 / 2)
        .background(item.variant.chipFillColor)
        .clipShape(Capsule())
    }

    /// The detail line. For a success row with a `variationKey`, the key is split
    /// out as an explicit SF Mono segment ("Variation `variant-a`"); otherwise the
    /// detail (an error message whose own keys are already backtick-styled text)
    /// renders as plain system-label body text.
    @ViewBuilder
    private var detailLine: some View {
        if let variationKey = item.variationKey {
            (
                Text("Variation ")
                    + Text(variationKey).font(ConvertTheme.monospacedBody())
            )
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(item.detail)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The fused VoiceOver label: success leads with the variation + experience,
    /// error leads with "Error:" then the message. Color is never the only signal —
    /// this label carries the outcome for non-visual users.
    private var accessibilityLabel: String {
        switch item.variant {
        case .success:
            if let variationKey = item.variationKey {
                return "Variation \(variationKey) for \(item.title)"
            }
            return item.detail
        case .error:
            return "Error: \(item.detail)"
        }
    }
}

#if DEBUG
struct ResultCard_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: ConvertTheme.space3) {
            ResultCard(
                ResultCard.Item(
                    title: "pricing-test",
                    detail: "Variation variant-a",
                    variationKey: "variant-a",
                    variant: .success
                )
            )
            ResultCard(
                ResultCard.Item(
                    title: "pricing-test",
                    detail: "No variation for experience `pricing-test`.",
                    hint: "Check experience config or audience eligibility.",
                    variant: .error
                )
            )
            ResultCard(
                ResultCard.Item(
                    title: "No variation",
                    detail: "No variation yet — SDK still loading config, or the visitor is ineligible.",
                    variant: .error
                )
            )
        }
        .padding(ConvertTheme.space5)
        .background(Color(.systemGroupedBackground))
        .previewLayout(.sizeThatFits)
    }
}
#endif
