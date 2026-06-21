import SwiftUI

/// Root of the Convert SDK demo: the five-tab `TabView` host (Story 7.3 / DEMO-3).
///
/// Replaces the temporary launch placeholder from Story 7.1. Each tab hosts a
/// titled shell view (`Tabs/*View.swift`) that owns its own `NavigationView`;
/// the later screen stories (7.3–7.6) fill those shells in. Selection is bound to
/// a ``DemoTab`` enum so the Experiences tab is the start tab, and the app-wide
/// Convert accent is applied via `.tint(ConvertTheme.accent)` so the selected-tab
/// tint matches the brand (AC2 / DEMO-4 handoff).
struct ContentView: View {

    /// The five demo tabs, in display order. `Hashable` so each can be a `.tag`.
    private enum DemoTab: Hashable {
        case experiences
        case features
        case conversions
        case offline
        case config
    }

    /// Selected tab. Defaults to `.experiences` so it is the start tab.
    @State private var selection: DemoTab = .experiences

    var body: some View {
        TabView(selection: $selection) {
            ExperiencesView()
                .tabItem { Label("Experiences", systemImage: "testtube.2") }
                .tag(DemoTab.experiences)

            FeaturesView()
                .tabItem { Label("Features", systemImage: "bolt.fill") }
                .tag(DemoTab.features)

            ConversionsView()
                .tabItem { Label("Conversions", systemImage: "dollarsign.circle") }
                .tag(DemoTab.conversions)

            OfflineView()
                .tabItem { Label("Offline", systemImage: "wifi.slash") }
                .tag(DemoTab.offline)

            ConfigView()
                .tabItem { Label("Config", systemImage: "gearshape") }
                .tag(DemoTab.config)
        }
        .tint(ConvertTheme.accent)
    }
}
