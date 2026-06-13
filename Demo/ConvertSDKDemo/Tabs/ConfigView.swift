import SwiftUI

/// The Config tab shell — titled empty state only (Story 7.3 / DEMO-3).
///
/// The real screen (masked SDK key, environment, tracking state, the config
/// state machine) is Story 7.6; this shell stands up the nav bar, title, empty
/// state, and the shared Event-Inspector toolbar button so the tab is navigable
/// today.
struct ConfigView: View {
    var body: some View {
        NavigationView {
            EmptyStateView(
                systemImage: "gearshape",
                title: "Configuration",
                hint: "Masked key, environment, and tracking state load here."
            )
            .navigationTitle("Config")
            .inspectorToolbar()
        }
        .navigationViewStyle(.stack)
    }
}
