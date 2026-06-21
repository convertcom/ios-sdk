import SwiftUI

/// A centered, actionable empty state for a tab shell (Story 7.3 / DEMO-3).
///
/// `ContentUnavailableView` would be the native fit, but it is iOS 17+, and the
/// demo's floor is iOS 15 — so this is a hand-rolled equivalent: an SF Symbol,
/// a title, and a short hint, all centered. Factoring it out keeps the five tab
/// shells from each repeating the same VStack layout (DRY / copy-paste-detector
/// discipline); each shell supplies only its symbol and copy.
///
/// Story 7.3–7.6 replace each shell's body with its real screen, at which point
/// the relevant shells stop using this view.
struct EmptyStateView: View {

    /// SF Symbol shown above the title — conventionally the tab's own symbol.
    let systemImage: String

    /// One-line state title, e.g. "No experiences run yet".
    let title: String

    /// Short actionable hint rendered in the secondary label color.
    let hint: String

    var body: some View {
        VStack(spacing: ConvertTheme.space3) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(ConvertTheme.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
