// Tests/ConvertSwiftSDKTests/BackgroundDelivery/BackgroundSessionManagerTests.swift
import Testing
import Foundation
@testable import ConvertSwiftSDK

// RED phase (Epic 5, Story 5.3): this suite exercises `BackgroundSessionManager`, the owner of the
// durable background `URLSession` used to deliver the queued tracking batch, which DOES NOT EXIST
// YET — the GREEN step creates it at `Sources/ConvertSwiftSDK/BackgroundDelivery/BackgroundSessionManager.swift`.
// Until then this file fails to compile with "cannot find 'BackgroundSessionManager' in scope",
// which is the ONLY expected RED symbol for this TDD cycle. Everything ELSE referenced here — the
// `Flag` reference holder, the `makeBackgroundSessionManager` builder, and the `MockEventQueueStore`
// it constructs (in `Support/MockEventQueueStore.swift`) — MUST compile.
//
// ── Contract under test (for the GREEN implementer) ───────────────────────────
// `final class BackgroundSessionManager: @unchecked Sendable` with:
//   * `static let sessionIdentifier = "com.convertexperiments.sdk.background-upload"` — the
//     `URLSessionConfiguration.background(withIdentifier:)` identifier (a session-identifier STRING,
//     not a file path).
//   * `static func makeConfiguration(sdkVersion:) -> URLSessionConfiguration` building a background
//     configuration with `sessionSendsLaunchEvents = true`, `isDiscretionary = false`, a
//     `"User-Agent": "ConvertAgent/\(sdkVersion)"` entry in `httpAdditionalHeaders` (set ONCE on the
//     session, not per request), `timeoutIntervalForRequest = 30`, and a bounded
//     `timeoutIntervalForResource`.
//   * `init(sdkVersion:store:eventBus:)` constructing a `BackgroundUploadDelegate` + `URLSession`.
//   * `var backgroundCompletionHandler: (() -> Void)?` (settable; stored `nonisolated(unsafe)`).
//   * `func enqueueUpload(fileURL:request:)` creating an `uploadTask(with:fromFile:).resume()`.
//
// ── Why only ONE case constructs a manager ────────────────────────────────────
// Constructing a `BackgroundSessionManager` creates a REAL `URLSession(configuration: .background(...))`
// keyed by the FIXED `sessionIdentifier`. Two managers with the same identifier alive in one process
// provoke a runtime "session already exists" warning, so the construction is confined to the single
// case that genuinely needs an instance (`completionHandlerIsStoredAndInvokable`). The two
// configuration cases call ONLY the static `makeConfiguration`, which creates no session.

/// A minimal reference holder a closure can flip and a test can later read. Captured by reference so
/// the `backgroundCompletionHandler` closure mutates the SAME cell the assertion inspects. A `class`
/// (not a captured `var`) sidesteps Swift 6's "mutation of captured var in escaping closure" data-race
/// diagnostic: the handler type is a non-`Sendable` `(() -> Void)?`, the holder is touched only
/// synchronously on one thread within the single case, so a bare `final class` is sound and warning-free.
private final class Flag {
    var value = false
}

@Suite("BackgroundSessionManager")
struct BackgroundSessionManagerTests {
    // MARK: - Shared builder (defined once — SonarQube new-code dup gate ≤ 3%)

    /// The single construction path for the SUT: wires it over `store`, a fresh ``EventBus``, and the
    /// given `sdkVersion`. Every case that needs an instance goes through here so the `init` call is
    /// never copy-pasted (SonarQube duplication gate). Defaults keep call sites to a bare `()`.
    private func makeBackgroundSessionManager(
        sdkVersion: String = "1.0.0",
        store: any EventQueueStore = MockEventQueueStore()
    ) -> BackgroundSessionManager {
        BackgroundSessionManager(sdkVersion: sdkVersion, store: store, eventBus: EventBus())
    }

    // MARK: - Cases

    /// The background configuration carries every property the durable-delivery contract requires:
    /// the fixed session identifier, OS launch events enabled, discretionary scheduling disabled (the
    /// batch must go out promptly, not whenever the OS deems convenient), a `ConvertAgent/...`
    /// User-Agent set on the session, and a 30s per-request timeout. Static-only: no session is created.
    @Test("background session configuration sets all required properties")
    func configurationSetsAllRequiredProperties() {
        let config = BackgroundSessionManager.makeConfiguration(sdkVersion: "1.0.0")

        #expect(config.identifier == "com.convertexperiments.sdk.background-upload")
        #expect(config.sessionSendsLaunchEvents == true)
        #expect(config.isDiscretionary == false)
        #expect((config.httpAdditionalHeaders?["User-Agent"] as? String)?.hasPrefix("ConvertAgent/") == true)
        #expect(config.timeoutIntervalForRequest == 30)
    }

    /// The `ConvertAgent/<version>` User-Agent is set ONCE in `httpAdditionalHeaders` on the session
    /// configuration (so every background upload inherits it) rather than stamped per `URLRequest`.
    /// Asserting the exact string for a distinct version pins both the format and the wiring location.
    /// Static-only: no session is created.
    @Test("ConvertAgent user-agent is set in httpAdditionalHeaders not per-request")
    func userAgentIsSetInConfigurationHeaders() {
        let config = BackgroundSessionManager.makeConfiguration(sdkVersion: "2.5.0")

        #expect(config.httpAdditionalHeaders?["User-Agent"] as? String == "ConvertAgent/2.5.0")
    }

    /// The app hands the SDK its `handleEventsForBackgroundURLSession` completion handler; the manager
    /// stores it and must be able to invoke it (later, from the delegate's finish-events callback). A
    /// synchronous set-then-call proves the property round-trips and is callable. The single case that
    /// constructs a real manager — see the file header on why session creation is confined here.
    @Test("the background completion handler is stored and invokable")
    func completionHandlerIsStoredAndInvokable() {
        let manager = makeBackgroundSessionManager()
        let flag = Flag()

        manager.backgroundCompletionHandler = { flag.value = true }
        manager.backgroundCompletionHandler?()

        #expect(flag.value == true)
    }
}
