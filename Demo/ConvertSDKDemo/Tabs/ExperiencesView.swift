import SwiftUI

/// The Experiences tab shell — titled empty state only (Story 7.3 / DEMO-3).
///
/// The real screen (bucketing an experience via a Run action, result cards, etc.)
/// is a later story; this shell stands up the nav bar, title, empty state, and the
/// shared Event-Inspector toolbar button so the tab is navigable today.
struct ExperiencesView: View {
    var body: some View {
        NavigationView {
            EmptyStateView(
                systemImage: "testtube.2",
                title: "No experiences run yet",
                hint: "Tap Run to bucket an experience."
            )
            .navigationTitle("Experiences")
            .inspectorToolbar()
        }
        .navigationViewStyle(.stack)
    }
}
