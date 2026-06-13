import SwiftUI

/// The Offline tab shell — titled empty state only (Story 7.3 / DEMO-3).
///
/// The real screen (live connectivity status and the offline-delivery narrative)
/// is a later story; this shell stands up the nav bar, title, empty state, and
/// the shared Event-Inspector toolbar button so the tab is navigable today.
struct OfflineView: View {
    var body: some View {
        NavigationView {
            EmptyStateView(
                systemImage: "wifi.slash",
                title: "Connectivity",
                hint: "Online / offline status and the offline-delivery narrative."
            )
            .navigationTitle("Offline")
            .inspectorToolbar()
        }
        .navigationViewStyle(.stack)
    }
}
