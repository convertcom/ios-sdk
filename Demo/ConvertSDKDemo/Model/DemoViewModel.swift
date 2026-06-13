import ConvertSDK
import SwiftUI

/// App-level state for the Convert SDK demo.
///
/// Owns the single ``ConvertSDK`` instance (keeping the SDK out of the App
/// struct and out of any View's value semantics) and publishes a coarse
/// ``ConfigState`` the UI can observe. `@MainActor` because it publishes UI
/// state that SwiftUI observes on the main actor.
///
/// Story 7.1 scope: construct the SDK against the FS-Test-Proj staging project
/// and kick off readiness *best-effort*. It deliberately does NOT act on the
/// outcome of `ready()` beyond flipping a minimal published state — the real
/// config state machine (timeout, WARN-before-READY, retries) is Story 7.6.
@MainActor
final class DemoViewModel: ObservableObject {

    /// The single SDK instance, owned for the app's lifetime.
    ///
    /// `ConvertSDK` is `final class … Sendable`, so it is held directly with no
    /// `@unchecked` wrapper under `SWIFT_STRICT_CONCURRENCY: complete`.
    let sdk: ConvertSDK

    /// Coarse readiness signal for the UI. Minimal Story 7.1 stub; Story 7.6
    /// replaces the transitions here with the full state machine.
    @Published private(set) var configState: ConfigState = .loading

    init() {
        // FS-Test-Proj staging: account 10035569 / project 10034190. The
        // "account/project" sdkKey form resolves to the live config URL
        // {apiConfigEndpoint}/config/10035569/10034190 on the default CDN
        // (cdn-4.convertexperiments.com/api/v1). No secret is required for
        // the demo to compile and launch-init; live decisioning is Story 7.3+.
        let configuration = ConvertConfiguration(sdkKey: "10035569/10034190")
        sdk = ConvertSDK(configuration: configuration)
    }

    /// Fires SDK readiness best-effort, off the UI thread.
    ///
    /// `ready()` is awaited (it suspends; it does not block the main actor) and
    /// the throw is swallowed in Story 7.1 — a transient network failure resolves
    /// degraded rather than throwing, and the only thrown case (unrecoverable
    /// config) is surfaced through ``ConfigState`` here as a placeholder. Story 7.6
    /// owns the real error surfacing.
    func start() async {
        do {
            try await sdk.ready()
            configState = .loaded
        } catch {
            configState = .failed(reason: error.localizedDescription)
        }
    }
}
