import ConvertSDK
import SwiftUI

/// The Convert SDK demo application entry point (Story 7.1 / DEMO-2).
///
/// Holds app-level state via a single ``DemoViewModel`` `@StateObject` that owns
/// the ``ConvertSDK`` instance, injects it into the view tree as an environment
/// object, and kicks off SDK readiness off the UI thread from `.task`.
///
/// The root is ``ContentView`` — the five-tab `TabView` (Story 7.3 / DEMO-3),
/// which applies the app-wide `.tint(ConvertTheme.accent)` itself, so no tint is
/// applied here. The view model is still injected and readiness still fires here
/// so the tab tree (and Story 7.6's config state machine) can observe it.
@main
struct ConvertSDKDemoApp: App {

    /// App-lifetime state, owning the SDK. `@StateObject` so SwiftUI creates it
    /// exactly once for the app's lifetime.
    @StateObject private var viewModel = DemoViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                // Fire-and-forget readiness: `.task` runs in an async context
                // (off the UI thread) and `start()` swallows the result. Story
                // 7.6 consumes readiness via the ConfigState machine.
                .task {
                    await viewModel.start()
                }
        }
    }
}
