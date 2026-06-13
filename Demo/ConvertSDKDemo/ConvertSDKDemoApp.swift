import ConvertSDK
import SwiftUI

/// The Convert SDK demo application entry point (Story 7.1 / DEMO-2).
///
/// Holds app-level state via a single ``DemoViewModel`` `@StateObject` that owns
/// the ``ConvertSDK`` instance, injects it into the view tree as an environment
/// object, and kicks off SDK readiness from `.task` without blocking the UI.
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
                // Subscribe the Event Inspector BEFORE firing readiness so the
                // lifecycle events emitted during init (`.ready`, `.configUpdated`,
                // any early `.bucketing`) are observed rather than missed — the
                // subscription is fast (it only registers listeners) and does not
                // block `start()`. Then fire-and-forget readiness: `start()` is
                // `@MainActor` and runs on the main actor, but `await`ing `ready()`
                // only *suspends* — it never blocks the UI (the SDK does its I/O
                // internally). The result is swallowed here; Story 7.6 consumes
                // readiness via the ConfigState machine. The matching
                // `stopEventInspector()` teardown is wired separately.
                .task {
                    await viewModel.startEventInspector()
                    await viewModel.start()
                }
        }
    }
}
