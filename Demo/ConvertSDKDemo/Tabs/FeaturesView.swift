import SwiftUI

/// The Features tab shell — titled empty state only (Story 7.3 / DEMO-3).
///
/// The real screen (evaluating a feature and rendering its typed variables) is a
/// later story; this shell stands up the nav bar, title, empty state, and the
/// shared Event-Inspector toolbar button so the tab is navigable today.
struct FeaturesView: View {
    var body: some View {
        NavigationView {
            EmptyStateView(
                systemImage: "bolt.fill",
                title: "No features evaluated yet",
                hint: "Evaluate a feature to see its typed variables."
            )
            .navigationTitle("Features")
            .inspectorToolbar()
        }
        .navigationViewStyle(.stack)
    }
}
