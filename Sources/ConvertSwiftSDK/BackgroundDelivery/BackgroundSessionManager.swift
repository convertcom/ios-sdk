// BackgroundSessionManager.swift
// Owner of the durable BACKGROUND `URLSession` (Epic 5 / Story 5.3) that delivers the queued
// tracking batch even after the app is suspended or terminated. Lives in the `ConvertSwiftSDK` target
// because it composes the URLSession-backed background transport; the ports it wires
// (``EventQueueStore``) and the bus it fires on (``EventBus``) are Foundation-only and live in the
// pure-logic `ConvertSwiftSDKCore`.
//
// Scope: this type configures, creates, and feeds the background session and holds the
// integrator-forwarded completion handler. It does NOT manage app-lifecycle background time —
// `beginBackgroundTask` lives in `LifecycleObserver`, so `UIKit` is intentionally NOT imported here.
//
// BGProcessingTask deferred to Post-MVP per architecture.md §Deferred Decisions — this manager uses
// ONLY a background `URLSession`; the `BackgroundTasks` framework is intentionally NOT imported.
import Foundation
import ConvertSwiftSDKCore

/// The background-upload testability seam the ``LifecycleObserver`` depends on — mirroring how
/// `ConfigRefreshScheduler` depends on `any ConfigProviding` rather than the concrete fetch service.
/// The observer holds `any BackgroundUploadEnqueueing` and calls ``enqueueUpload(fileURL:request:)``
/// on a background transition, so a test injects a recording double (`MockBackgroundSessionManager`)
/// in place of the real `URLSession`-backed manager.
///
/// The requirement is declared `async` (even though the real ``BackgroundSessionManager`` body has
/// no suspension — it just builds and `resume()`s an upload task) so an `actor` double can satisfy it
/// and hand the observer's test an awaitable happens-before. A synchronous body trivially conforms to
/// an `async` requirement; the observer calls it as `await sessionManager.enqueueUpload(...)`.
///
/// `package` (NOT `public`, NOT bare `internal`): the conforming test double
/// (`MockBackgroundSessionManager`) lives in the `ConvertSwiftSDKTests` target and reaches this seam through
/// a PLAIN `import ConvertSwiftSDK` (not `@testable`), so a bare-`internal` protocol would be invisible to
/// it; `package` grants exactly that in-package cross-target visibility while keeping the seam OFF the
/// SDK's public consumer surface — mirroring how `EventBus/fire` uses `package` for an identical
/// in-package-only need.
package protocol BackgroundUploadEnqueueing: AnyObject, Sendable {
    /// Enqueues one durable background upload of the on-disk batch file streamed as the request body.
    /// - Parameters:
    ///   - fileURL: The on-disk batch file to stream as the request body.
    ///   - request: The configured upload request (URL/method/headers).
    func enqueueUpload(fileURL: URL, request: URLRequest) async
}

/// Configures, owns, and feeds the durable background `URLSession` that ships the queued tracking
/// batch, and holds the integrator-forwarded background completion handler the delegate invokes once
/// the session's work is acknowledged.
///
/// Concurrency shape — the ONE sanctioned `@unchecked Sendable` carve-out for this type
/// (architecture.md §Process Patterns explicitly names "the `BackgroundSessionManager` that owns the
/// background `URLSession`"): the background session's delegate callbacks arrive on the session's
/// serial delegate queue, and ``backgroundCompletionHandler`` is a non-`Sendable` `(() -> Void)?`
/// that is SET only from the SDK's internal flow and READ on that serial delegate queue — so an
/// `actor` cannot mediate it without breaking the synchronous delegate contract. The suppression is
/// sound because ``sdkVersion``/``store``/``eventBus`` are immutable `let`s, ``backgroundSession`` /
/// ``delegate`` are written only during `init`/``recreateSession()`` on the constructing thread, and
/// ``backgroundCompletionHandler`` is the single `nonisolated(unsafe)` field whose access pattern
/// (write-once on the internal flow, read on the serial delegate queue) is documented at its
/// declaration. This is the only suppression in the file.
final class BackgroundSessionManager: BackgroundUploadEnqueueing, @unchecked Sendable {
    /// The canonical, never-changing `URLSessionConfiguration.background(withIdentifier:)` identifier.
    /// This is the ONLY place the literal appears; the OS keys the resumable background session by it,
    /// so it must remain stable across launches and unique within the process.
    static let sessionIdentifier = "com.convertexperiments.sdk.background-upload"

    /// The SDK version stamped into the non-overridable `ConvertAgent/<version>` User-Agent.
    private let sdkVersion: String
    /// The durable pending-event-queue persistence port handed to the delegate (load/clear on outcome).
    private let store: any EventQueueStore
    /// The in-process bus the delegate fires the delivered-batch (`apiQueueReleased`) event on.
    private let eventBus: EventBus

    /// The durable background session; nil only before the first ``recreateSession()``. Mutated solely
    /// during `init`/``recreateSession()`` on the constructing thread (covered by the `@unchecked`
    /// carve-out).
    private var backgroundSession: URLSession?
    /// The session's delegate, retained here so it outlives the session. Set in ``recreateSession()``.
    private var delegate: BackgroundUploadDelegate?

    /// The optional integrator-forwarded `handleEventsForBackgroundURLSession` completion handler.
    ///
    /// `nonisolated(unsafe)`: it is SET once from the SDK's internal flow (when the app hands the SDK
    /// its handler) and READ on the background session's serial delegate queue (via the delegate's
    /// `completionHandlerProvider`) — never concurrently mutated. This single-writer/serial-reader
    /// pattern is exactly the access the `@unchecked Sendable` carve-out sanctions for this type, so
    /// the `(() -> Void)?` (a non-`Sendable` closure) is held without an actor.
    nonisolated(unsafe) var backgroundCompletionHandler: (() -> Void)?

    /// Wires the manager to its SDK version, durable store, and event bus, then builds the background
    /// session eagerly so it is ready to accept uploads (and resumes any session the OS relaunched us
    /// to finish).
    ///
    /// - Parameters:
    ///   - sdkVersion: The version stamped into the `ConvertAgent/<version>` User-Agent.
    ///   - store: The durable pending-event-queue persistence port.
    ///   - eventBus: The in-process bus the delivered-batch event is fired on.
    init(sdkVersion: String, store: any EventQueueStore, eventBus: EventBus) {
        self.sdkVersion = sdkVersion
        self.store = store
        self.eventBus = eventBus
        recreateSession()
    }

    /// (Re)builds the background `URLSession` and its delegate. The delegate reads
    /// ``backgroundCompletionHandler`` lazily through a `[weak self]` provider closure (AR12 — the
    /// session retains the delegate, so a strong capture would form a retain cycle), so a handler set
    /// AFTER session creation is still observed on the finish-events callback.
    func recreateSession() {
        let config = Self.makeConfiguration(sdkVersion: sdkVersion)
        let delegate = BackgroundUploadDelegate(
            store: store,
            eventBus: eventBus,
            completionHandlerProvider: { [weak self] in self?.backgroundCompletionHandler }
        )
        self.delegate = delegate
        self.backgroundSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Builds the background session configuration carrying every durable-delivery property: launch
    /// events so the OS relaunches us to finish, non-discretionary scheduling so the batch goes out
    /// promptly, the non-overridable `ConvertAgent/<version>` User-Agent set ONCE on the session, and
    /// bounded request/resource timeouts.
    ///
    /// - Parameter sdkVersion: The version stamped into the `ConvertAgent/<version>` User-Agent.
    /// - Returns: The configured background `URLSessionConfiguration`.
    static func makeConfiguration(sdkVersion: String) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpAdditionalHeaders = ["User-Agent": "ConvertAgent/\(sdkVersion)"]
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600  // bounded — NOT the 7-day URLSession default (FR45)
        return config
    }

    /// Enqueues one durable background upload of the on-disk batch file. A no-op if the session has
    /// not been built yet.
    ///
    /// `uploadTask(with:fromFile:)` is the ONLY permitted upload method on a background session: it
    /// streams the body from disk so the upload survives app suspension/termination. `dataTask` and
    /// the in-memory `uploadTask(with:from:)` are PROHIBITED on background sessions (FR36).
    ///
    /// - Parameters:
    ///   - fileURL: The on-disk batch file to stream as the request body.
    ///   - request: The configured upload request (URL/method/headers).
    ///
    /// `async` to satisfy the ``BackgroundUploadEnqueueing`` seam (whose `async` requirement lets an
    /// `actor` double conform and gives the observer's test an awaitable happens-before). The body has
    /// no suspension — building and `resume()`ing the upload task is synchronous — which validly
    /// satisfies an `async` requirement.
    func enqueueUpload(fileURL: URL, request: URLRequest) async {
        guard let session = backgroundSession else { return }
        // Mark a durable background upload outstanding BEFORE creating the task, so a foreground-recovery
        // flush / cold-start recovery that races this background transition observes the marker and
        // declines to read or clear the same on-disk batch (cross-path exactly-once — Story 5.3 / F-052).
        // `BackgroundUploadDelegate.reconcile()` clears it on every outcome. `try?`: a marker-write
        // failure degrades to the prior (uncoordinated) behavior rather than throwing out of the
        // lifecycle hook — matching the no-throw store philosophy across the durable-delivery path.
        try? await store.markBackgroundUploadInFlight()
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.resume()
    }

    /// Tears the background session down on deallocation, cancelling any in-flight task (AC13 cleanup)
    /// so a stale session keyed by the fixed identifier cannot linger in the process.
    deinit {
        backgroundSession?.invalidateAndCancel()
    }
}
