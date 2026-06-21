import SwiftUI

/// A grouped info panel that renders the demo's active SDK configuration as a
/// key/value list (Story 7.6 / DEMO-6 `config-info-panel`).
///
/// The panel is the one place in the app that owns the SDK Key, Environment,
/// Experience Key, Feature Key, and Tracking state as a readable, skimmable
/// surface. It consumes a ``ConfigPanelData`` value — assembled by
/// ``DemoViewModel/configPanelData`` — so each field is already display-safe
/// (the masked SDK key has been routed through `toLoggable`, etc.) before
/// it arrives here.
///
/// **Color rule (DESIGN.md hard rule):** all label/value text is a system label
/// color (`.primary` / `.secondary`) — brand hues are never used as body text.
/// The ``StatusBadge`` that renders the Tracking row carries the four-channel
/// color-independent pattern on its own; no additional brand color appears here.
///
/// **A11y rule:** each row collapses into one `accessibilityElement` whose fused
/// `.accessibilityLabel` reads "label, value", mirroring ``StatusBadge``'s
/// `(children: .ignore)` + fused-label idiom. The Tracking row's
/// ``StatusBadge`` already supplies its own VoiceOver label (e.g.
/// "On, delivered"); the wrapping row element ignores children so it can fuse
/// the field name into the announcement: "Tracking, On, delivered".
///
/// **DRY note (SonarQube CPD discipline):** the five rows share the same
/// HStack shape — key label leading, value trailing — so a single `row(_:_:)`
/// builder handles the four text-value rows and a `@ViewBuilder` overload
/// `row(_:content:)` handles the Tracking row whose value is a `StatusBadge`.
struct ConfigInfoPanel: View {

    /// The configuration snapshot this panel renders.
    private let data: ConfigPanelData

    /// - Parameter data: The display-safe configuration bundle from the view model.
    init(_ data: ConfigPanelData) {
        self.data = data
    }

    var body: some View {
        VStack(spacing: 0) {
            row("SDK Key") {
                Text(data.maskedKey)
                    .font(ConvertTheme.monospacedBody())
                    // The masked key may be long; wrap rather than truncate
                    // (DESIGN.md "mono cells wrap, never truncate").
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
            } a11yValue: { data.maskedKey }

            divider

            row("Environment") {
                Text(data.environment)
                    .foregroundStyle(.primary)
            } a11yValue: { data.environment }

            divider

            row("Experience") {
                Text(data.experienceKey)
                    .foregroundStyle(.primary)
            } a11yValue: { data.experienceKey }

            divider

            row("Feature") {
                Text(data.featureKey)
                    .foregroundStyle(.primary)
            } a11yValue: { data.featureKey }

            divider

            // Tracking row: the value is a StatusBadge, not plain text.
            // StatusBadge already owns the four-channel a11y; the row fuses
            // the field name ("Tracking") in front of the badge's own label.
            row("Tracking") {
                StatusBadge(
                    data.trackingEnabled ? "On" : "Off",
                    style: data.trackingEnabled ? .delivered : .queued
                )
            } a11yValue: { data.trackingEnabled ? "On, delivered" : "Off, queued" }
        }
        .padding(ConvertTheme.space4)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: ConvertTheme.radiusMd, style: .continuous))
    }

    // MARK: - Row builder

    /// A single labeled row: key on the leading side, an arbitrary value view on
    /// the trailing side. The row fuses into one VoiceOver element whose label is
    /// `"<label>, <a11yValue>"` — same pattern as ``StatusBadge``.
    ///
    /// - Parameters:
    ///   - label:     The field name rendered in `.subheadline` / `.secondary`.
    ///   - content:   The trailing value view (text, badge, etc.).
    ///   - a11yValue: A closure that returns the plain-text VoiceOver value.
    @ViewBuilder
    private func row<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content,
        a11yValue: () -> String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ConvertTheme.space2) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: ConvertTheme.space2)

            content()
                .font(.body)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, ConvertTheme.space2)
        // Fuse the row so VoiceOver reads "label, value" as one element —
        // no double-read of the key label and value separately.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(a11yValue())")
    }

    /// A hairline divider between rows — uses the system separator color so it
    /// auto-adapts light/dark without a hardcoded color.
    private var divider: some View {
        Divider()
    }
}

// MARK: - Preview

#if DEBUG
struct ConfigInfoPanel_Previews: PreviewProvider {
    static var previews: some View {
        ConfigInfoPanel(
            ConfigPanelData(
                maskedKey: "10035569/10034190",
                environment: "default",
                experienceKey: "experience_key_1",
                featureKey: "feature_key_1",
                trackingEnabled: true
            )
        )
        .padding(ConvertTheme.space5)
        .background(Color(.systemGroupedBackground))
        .previewLayout(.sizeThatFits)
        .previewDisplayName("Loaded — tracking on")

        ConfigInfoPanel(
            ConfigPanelData(
                maskedKey: "sk_live_abcdefghijklmnop…ef01",
                environment: "staging",
                experienceKey: "long-experience-key-for-layout-test",
                featureKey: "feature-flag-key",
                trackingEnabled: false
            )
        )
        .padding(ConvertTheme.space5)
        .background(Color(.systemGroupedBackground))
        .previewLayout(.sizeThatFits)
        .previewDisplayName("Loaded — tracking off, long keys")
    }
}
#endif
