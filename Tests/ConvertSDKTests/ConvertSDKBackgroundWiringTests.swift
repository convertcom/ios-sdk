// Tests/ConvertSDKTests/ConvertSDKBackgroundWiringTests.swift
//
// RED-phase contract for WIRING durable background delivery (Epic 5 / Story 5.3 — PLAT-4 wiring
// phase) into `ConvertSDK`, and for the public `handleEventsForBackgroundURLSession(identifier:
// completionHandler:)` entry point the integrator forwards its `UIApplicationDelegate` callback
// through. Both the `BackgroundSessionManager` ACTOR-of-record and the `LifecycleObserver` already
// exist and are unit-tested in isolation (`BackgroundSessionManagerTests` / `LifecycleObserverTests`).
// What does NOT exist yet is the composition-root wiring that CONSTRUCTS a `BackgroundSessionManager`
// (and a `LifecycleObserver` over it) inside `ConvertSDK`, holds the manager on an internal property
// the test can read, and the public method that lands the integrator's completion handler on it.
//
// ── What makes this RED, and why it is the RIGHT reason ─────────────────────────────────────────────
// The two scenario tests call `sdk.handleEventsForBackgroundURLSession(identifier:completionHandler:)`
// and read `sdk.backgroundSessionManager?.backgroundCompletionHandler`. `ConvertSDK` (verified:
// `Sources/ConvertSDK/ConvertSDK.swift`) declares NEITHER today — so this file fails to compile with
// "value of type 'ConvertSDK' has no member 'handleEventsForBackgroundURLSession'" and "… has no member
// 'backgroundSessionManager'". Those two members are EXACTLY the seams the GREEN (PLAT-4) phase adds.
// Everything else here already compiles: `MockConfigProvider.ungated` (Support/MockPorts.swift),
// `makeRefreshConfig` (Support/TestFixtures.swift), `ConvertConfiguration`, `ConvertSDK`'s internal
// init + `ready()`, AND `BackgroundSessionManager.sessionIdentifier` (an EXISTING `static let` on the
// manager, reachable here through `@testable import ConvertSDK`). The compile-fail is isolated to the
// missing wiring seams — no other symbol in this file is novel.
//
// ── Assumed GREEN seams (so the implementer matches these call sites) ───────────────────────────────
//   // An internal (NOT private) stored property — mirroring the `configStore` precedent (the test
//   // target reaches it) — set to the constructed manager on the standard key path. Optional because
//   // paths that do not wire background delivery leave it nil; the standard init sets it non-nil.
//   internal let backgroundSessionManager: BackgroundSessionManager?
//
//   // The integrator forwards `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
//   // here. The guard rejects any identifier other than the SDK's canonical background-session id, so
//   // a handler for an UNRELATED session is never stored on our manager.
//   public func handleEventsForBackgroundURLSession(
//       identifier: String,
//       completionHandler: @escaping @Sendable () -> Void
//   ) {
//       guard identifier == BackgroundSessionManager.sessionIdentifier else { return }
//       backgroundSessionManager?.backgroundCompletionHandler = completionHandler
//   }
//
// ── Why `MockConfigProvider.ungated` is the injected seam here ───────────────────────────────────────
// These tests need a READY SDK built OFF the network — they assert nothing about config refresh, so the
// non-counting `MockConfigProvider` (the same double `ConvertSDKTests.makeSut` injects) is the lightest
// fit: `ungated(cached: nil, live: <config>)` drives cache-miss → live-success → `ready()` non-degraded
// with no gate to release and no fetch count to track. The counting `MockConfigFetchService` (used by
// `ConvertSDKSchedulerWiringTests` to prove the refresh loop ticks) would add machinery this suite never
// reads — so the simpler provider is used, mirroring the entry-point suites.
//
// ── Determinism (NFR21 — 0-flake under parallel load) ───────────────────────────────────────────────
// The SOLE synchronization point is `await sdk.ready()`: it suspends until the SDK's detached config-load
// `Task` has resolved config and latched the ready gate. GREEN wires the background manager EITHER
// synchronously in `init` (set before the handle is returned) OR inside that same load `Task` (set by
// the time the ready latch fires) — in BOTH cases the manager is non-nil once `ready()` returns, so
// asserting AFTER `await ready()` is the happens-before that covers either wiring site. No `Task.sleep`,
// no wall-clock wait, no `NotificationCenter` post (the lifecycle observer's notification path is exercised
// at the `LifecycleObserverTests` unit level, not through this composition-root wiring test) — so nothing
// here can leak across parallel tests.
//
// NOTE on closure-equality: `backgroundCompletionHandler` is `(() -> Void)?` — a closure is NOT
// `Equatable`, so the assertions check OPTIONALITY (`!= nil` after a canonical-identifier store, `== nil`
// after a mismatched-identifier no-op), never closure identity.
import Testing
import Foundation
@testable import ConvertSDK

@Suite("ConvertSDK background wiring")
struct ConvertSDKBackgroundWiringTests {
    // MARK: - SUT

    /// Builds a REAL `ConvertSDK` wired to an UNGATED `MockConfigProvider` (cache miss + a non-nil
    /// `live`, so the load `Task` resolves `ready()` non-degraded) and awaits `ready()` — so by the time
    /// the SUT is returned, the SDK's detached config-load `Task` has progressed past the ready latch and
    /// any background-delivery wiring GREEN performs (synchronously in `init` OR inside that load `Task`)
    /// has run. Single construction site so neither scenario re-inlines the configuration build +
    /// internal-init call (SonarQube new-duplicated-lines gate; CPD is token-based, so SHARING this block
    /// — not renaming locals — is what keeps the diff under the threshold).
    ///
    /// `@MainActor` to mirror the existing wiring SUTs (`ConvertSDKTests.makeSut` /
    /// `ConvertSDKSchedulerWiringTests.makeWiringSut`): the SDK's internal init is non-async (the handle
    /// is built synchronously; config-load runs detached). `async throws` because it `await`s `ready()`
    /// (the wiring happens-before) and building the `live` `ProjectConfig` decodes JSON via the shared
    /// `makeRefreshConfig` builder.
    @MainActor
    private func makeSut() async throws -> ConvertSDK {
        // Cache MISS (`cached: nil`) + a non-nil `live`: the load `Task` does loadCachedConfig() → nil,
        // fetchLiveConfig() → live, setConfig(live) → ready non-degraded — entirely off the network.
        let provider = MockConfigProvider.ungated(cached: nil, live: try makeRefreshConfig())
        let configuration = ConvertConfiguration(sdkKey: "test-key")
        let sdk = ConvertSDK(configuration: configuration, configProvider: provider)
        // The happens-before: once `ready()` resolves, the load `Task` has run past the ready latch, so
        // GREEN's background wiring (in `init` OR in that `Task`) is in place before any assertion.
        try await sdk.ready()
        return sdk
    }

    // MARK: - Scenario 1 — the canonical identifier lands the handler on the manager

    /// PLAT-4 entry-point contract (positive): forwarding the integrator's completion handler with the
    /// SDK's CANONICAL background-session identifier stores that handler on the wired
    /// `BackgroundSessionManager`, so the background `URLSession` delegate can invoke it once the OS
    /// reports the relaunched session's events finished. Reads `backgroundCompletionHandler` through the
    /// internal `backgroundSessionManager` property (the same way the scheduler-wiring suite reads
    /// internal SDK state) and asserts it is now non-nil — the handler landed.
    @MainActor
    @Test("handleEventsForBackgroundURLSession with the canonical identifier stores the completion handler")
    func canonicalIdentifierStoresCompletionHandler() async throws {
        let sdk = try await makeSut()

        sdk.handleEventsForBackgroundURLSession(
            identifier: BackgroundSessionManager.sessionIdentifier,
            completionHandler: {}
        )

        #expect(sdk.backgroundSessionManager?.backgroundCompletionHandler != nil)
    }

    // MARK: - Scenario 2 — a mismatched identifier is a no-op (the guard rejects it)

    /// PLAT-4 entry-point contract (negative): forwarding a handler for some OTHER URLSession (an
    /// identifier that is NOT the SDK's canonical background-session id) is a no-op — the method's guard
    /// rejects the mismatch, so no handler is stored on our manager and the unrelated session's
    /// completion is left for whoever actually owns it. Asserts `backgroundCompletionHandler` is still
    /// nil (optionality, not closure identity — a closure is not `Equatable`).
    @MainActor
    @Test("handleEventsForBackgroundURLSession with a mismatched identifier is a no-op")
    func mismatchedIdentifierIsNoOp() async throws {
        let sdk = try await makeSut()

        sdk.handleEventsForBackgroundURLSession(
            identifier: "com.some.other.session",
            completionHandler: {}
        )

        #expect(sdk.backgroundSessionManager?.backgroundCompletionHandler == nil)
    }

    // MARK: - Scenario 3 — the SDK constructs with background delivery wired and ready() still resolves

    /// PLAT-4 wiring smoke (composition-root proof): a standard-key-path `ConvertSDK` constructs with a
    /// `BackgroundSessionManager` wired in AND `ready()` still resolves — i.e. adding the background
    /// manager / lifecycle observer to the composition root did not break the non-blocking-init / ready
    /// contract. `makeSut()` already `await`s `ready()`, so reaching this assertion proves ready resolved;
    /// the non-nil manager proves the wiring exists. Distinct signal from scenarios 1–2 (which exercise the
    /// public method), so it adds coverage without duplicating their bodies.
    @MainActor
    @Test("the SDK constructs with background delivery wired and ready() still resolves")
    func sdkConstructsWithBackgroundDeliveryWired() async throws {
        let sdk = try await makeSut()

        #expect(sdk.backgroundSessionManager != nil)
    }
}
