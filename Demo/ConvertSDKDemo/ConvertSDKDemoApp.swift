import ConvertSDK
import SwiftUI

/// The Convert SDK demo application entry point (Story 7.1 / DEMO-2).
///
/// Holds app-level state via a single ``DemoViewModel`` `@StateObject` that owns
/// the ``ConvertSDK`` instance, injects it into the view tree as an environment
/// object, and kicks off SDK readiness off the UI thread from `.task`.
///
/// The root is a TEMPORARY placeholder (see `body`). Story 7.3 (DEMO-3) replaces
/// it with `ContentView()` — the TabView root — and applies `.tint(ConvertTheme.accent)`
/// there, so no tint is applied here.
@main
struct ConvertSDKDemoApp: App {

    /// App-lifetime state, owning the SDK. `@StateObject` so SwiftUI creates it
    /// exactly once for the app's lifetime.
    @StateObject private var viewModel = DemoViewModel()

    var body: some Scene {
        WindowGroup {
            // TEMPORARY placeholder root for Story 7.1. DEMO-3 replaces this
            // whole `VStack` with `ContentView()` (the themed TabView) and adds
            // `.tint(ConvertTheme.accent)`.
            VStack(spacing: ConvertTheme.space3) {
                Text("Convert SDK Demo")
                    .font(.title2)
                Text("Initializing…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .environmentObject(viewModel)
            // Fire-and-forget readiness for Story 7.1: `.task` runs in an async
            // context (off the UI thread) and `start()` swallows the result.
            // Story 7.6 consumes readiness via the ConfigState machine.
            .task {
                await viewModel.start()
            }
        }
    }
}
