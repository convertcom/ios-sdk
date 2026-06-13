import SwiftUI

/// The Conversions tab shell — titled empty state only (Story 7.3 / DEMO-3).
///
/// The real screen (tracking a goal and showing success / dedup results) is a
/// later story; this shell stands up the nav bar, title, empty state, and the
/// shared Event-Inspector toolbar button so the tab is navigable today.
struct ConversionsView: View {
    var body: some View {
        NavigationView {
            EmptyStateView(
                systemImage: "dollarsign.circle",
                title: "No conversions tracked yet",
                hint: "Track a goal to see success / dedup results."
            )
            .navigationTitle("Conversions")
            .inspectorToolbar()
        }
        .navigationViewStyle(.stack)
    }
}
