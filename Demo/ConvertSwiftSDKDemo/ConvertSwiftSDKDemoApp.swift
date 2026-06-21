import ConvertSwiftSDK
import SwiftUI

/// The Convert SDK demo application entry point (Story 7.1 / DEMO-2).
///
/// Holds app-level state via a single ``DemoViewModel`` `@StateObject` that owns
/// the ``ConvertSwiftSDK`` instance, injects it into the view tree as an environment
/// object, and kicks off SDK readiness from `.task` without blocking the UI.
///
/// The root is ``ContentView`` — the five-tab `TabView` (Story 7.3 / DEMO-3),
/// which applies the app-wide `.tint(ConvertTheme.accent)` itself, so no tint is
/// applied here. The view model is still injected and readiness still fires here
/// so the tab tree (and Story 7.6's config state machine) can observe it.
@main
struct ConvertSwiftSDKDemoApp: App {

    /// App-lifetime state, owning the SDK. `@StateObject` so SwiftUI creates it
    /// exactly once for the app's lifetime.
    @StateObject private var viewModel = DemoViewModel()

    /// The current scene activation phase, observed so the Event Inspector
    /// subscription is torn down when the app moves to the background (see the
    /// `.onChange(of:)` below). `@Environment(\.scenePhase)` is available from
    /// iOS 14, so it is safe on the iOS 15 deployment floor.
    @Environment(\.scenePhase) private var scenePhase

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
                // `stopEventInspector()` teardown fires from the
                // `.onChange(of: scenePhase)` below, on the move to `.background`.
                .task {
                    await viewModel.startEventInspector()
                    await viewModel.start()
                }
                // Tear the Event Inspector subscription down when the app moves to
                // the background — the correct teardown point for the demo. The
                // `.task` above does NOT re-fire on return to foreground, and this
                // fix deliberately does not re-subscribe there; `startEventInspector()`
                // is idempotent, so even an unexpected re-invocation won't double
                // subscribe. Single-arg `.onChange(of:)` form for the iOS 15 floor
                // (the two-arg closure is iOS 16+).
                .onChange(of: scenePhase) { phase in
                    if phase == .background {
                        Task { await viewModel.stopEventInspector() }
                    }
                }
        }
    }
}
