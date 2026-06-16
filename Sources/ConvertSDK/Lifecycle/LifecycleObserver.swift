// LifecycleObserver.swift
// Durable background-delivery lifecycle observer (Epic 5 / Story 5.3). Lives in the `ConvertSDK`
// (platform) target — NOT the pure-logic `ConvertSDKCore` — because it observes app-lifecycle
// notifications and requests OS background time via UIKit (guarded); the queue it drives
// (`EventQueue`) and the background-upload seam (`BackgroundUploadEnqueueing`) it composes are wired
// from this target. BGProcessingTask is deferred Post-MVP (architecture.md §Deferred Decisions), so
// the `BackgroundTasks` framework is intentionally NOT imported — durable delivery rides ONLY the
// background `URLSession` the seam owns plus the `beginBackgroundTask` OS time requested here.

import Foundation
import ConvertSDKCore
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// The lifecycle side-effect engine: holds the runtime collaborators and the mutable background-task
/// id, and performs the background-persist / foreground-recovery work. An `actor`, so its sole mutable
/// state (``backgroundTaskID``) is race-free with NO lock and NO suppression — mirroring the `actor`
/// shape `EventQueue` / `ConfigRefreshScheduler` use for their isolated state.
///
/// ── Why a SEPARATE engine actor (not the observer doing the work itself) ─────────────────────────
/// ``LifecycleObserver`` registers its notification observers SYNCHRONOUSLY in `init` (so a
/// notification posted immediately after construction is not dropped — see the observer's type doc).
/// The `addObserver` blocks must therefore capture something that does the work — but capturing the
/// observer's `self` in those escaping blocks is illegal until ALL of the observer's stored properties
/// are initialized (Swift definite-initialization), and the OBSERVER-TOKEN property cannot be
/// initialized until AFTER registration returns the tokens — a cycle. Capturing THIS engine actor
/// (constructed BEFORE registration) instead breaks the cycle: the blocks hop straight into the engine
/// and never touch the observer's `self`, so the observer's token property can be assigned afterward.
/// The engine holds no reference back to the observer, so there is no retain cycle.
private actor LifecycleEngine {
    /// The background-task OS-time name; this is the only place the literal appears (mirroring how
    /// `BackgroundSessionManager` keeps its session identifier in one `static let`).
    private static let backgroundTaskName = "com.convertexperiments.sdk.flush"

    /// The real event queue this engine drives — its background-persist (`persistBeforeBackground`) and
    /// foreground-recovery (`flush`) effects are what AC1 / AC6 observe.
    private let eventQueue: EventQueue
    /// The durable background-upload seam the engine enqueues the on-disk batch through on a background
    /// transition.
    private let sessionManager: any BackgroundUploadEnqueueing
    /// The on-disk batch file the durable background upload streams from (production passes
    /// `CoordinatedFileEventQueueStore.queueFileURL()`; never hardcoded here).
    private let queueFileURL: URL
    /// The event-delivery base URL the engine builds its background-upload request against.
    private let trackEndpoint: String
    /// The OS background-task identifier for the in-flight background flush, or `.invalid` when none is
    /// held. Read by the expiration handler to end the task it named. The sole mutable state.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(
        eventQueue: EventQueue,
        sessionManager: any BackgroundUploadEnqueueing,
        queueFileURL: URL,
        trackEndpoint: String
    ) {
        self.eventQueue = eventQueue
        self.sessionManager = sessionManager
        self.queueFileURL = queueFileURL
        self.trackEndpoint = trackEndpoint
    }

    /// Background transition (AC1): request OS background time, persist the live buffer to disk, enqueue
    /// a durable background upload of that file, then end the background task.
    ///
    /// Order matters: `beginBackgroundTask` is requested FIRST so the OS keeps the process alive long
    /// enough to persist and enqueue; `persistBeforeBackground()` then moves the in-memory buffer to the
    /// on-disk queue file (making disk authoritative); the durable upload is enqueued from THAT file URL;
    /// finally the background task is ended so the OS time is released promptly. The background task is
    /// ended in BOTH the normal path and the expiration handler — `takeBackgroundTaskID()` returns and
    /// clears the id in one actor step, so it is ended exactly once.
    func handleBackground() async {
        await beginBackgroundTask()
        await eventQueue.persistBeforeBackground()

        var request = URLRequest(url: requestURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await sessionManager.enqueueUpload(fileURL: queueFileURL, request: request)

        await endBackgroundTask()
    }

    /// Foreground transition (AC6): trigger a foreground-recovery flush of the queue, so an undelivered
    /// batch a prior session persisted to disk is delivered through the queue's uploader on return to
    /// foreground.
    func handleForeground() async {
        await eventQueue.flush()
    }

    /// Requests OS background time on the `MainActor` (`UIApplication.shared.beginBackgroundTask` is
    /// `MainActor`-isolated) and stores the granted id. The expiration handler — invoked by the OS if
    /// the work outlives the granted window — ends the task it named and resets the id, so a forced
    /// expiry never strands a held background task. The handler captures `self` (this engine actor,
    /// which is `Sendable`) and hops back in to take-and-end the id exactly once.
    private func beginBackgroundTask() async {
        let id = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: Self.backgroundTaskName) { [self] in
                Task {
                    let expiringID = await takeBackgroundTaskID()
                    if expiringID != .invalid {
                        await MainActor.run { UIApplication.shared.endBackgroundTask(expiringID) }
                    }
                }
            }
        }
        backgroundTaskID = id
    }

    /// Ends the held background task (if any) on the `MainActor` and resets the stored id.
    /// `takeBackgroundTaskID()` returns and clears in one actor step, so this and the expiration handler
    /// cannot double-end the same id.
    private func endBackgroundTask() async {
        let id = takeBackgroundTaskID()
        guard id != .invalid else { return }
        await MainActor.run { UIApplication.shared.endBackgroundTask(id) }
    }

    /// Returns the current background-task id and resets the stored value to `.invalid` in ONE actor
    /// step, so the id is ended exactly once whether the work finishes normally or the OS expires it.
    private func takeBackgroundTaskID() -> UIBackgroundTaskIdentifier {
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        return id
    }

    /// The upload request URL: the configured track endpoint parsed as a `URL`, falling back to a file
    /// URL only if the endpoint string is not a valid URL (avoids a force-unwrap; the durable upload's
    /// file body still streams from ``queueFileURL`` regardless of the request URL).
    private func requestURL() -> URL {
        URL(string: trackEndpoint) ?? URL(fileURLWithPath: "/dev/null")
    }
}

/// Holds the two notification observer tokens behind an `actor` so ``LifecycleObserver`` can own them
/// through an immutable `let` and stay an all-`let` `Sendable final class` — the same boxing idiom
/// `SchedulerBox` uses for `ConfigRefreshScheduler`'s mutable handle.
///
/// The tokens are `any NSObjectProtocol` (NOT `Sendable`), so they cannot live directly on a `Sendable`
/// class. They are created in ``LifecycleObserver``'s `init` and handed to THIS actor's `init` as
/// parameters: an actor's `init` is nonisolated and runs in the caller's context, so passing the
/// non-`Sendable` tokens into it is NOT a cross-isolation *send* — they are created and consumed in the
/// same nonisolated `init` scope, then held actor-isolated thereafter. Routing them through a later
/// actor-isolated setter would instead be a send of a non-`Sendable` value (Swift 6 rejects it).
private actor LifecycleObserverTokens {
    /// The opaque token for the `willResignActive` observer, retained so teardown can remove it.
    private var resignObserver: (any NSObjectProtocol)?
    /// The opaque token for the `didBecomeActive` observer, retained so teardown can remove it.
    private var becomeActiveObserver: (any NSObjectProtocol)?

    init(resignObserver: any NSObjectProtocol, becomeActiveObserver: any NSObjectProtocol) {
        self.resignObserver = resignObserver
        self.becomeActiveObserver = becomeActiveObserver
    }

    /// Removes both observers from `center` (if registered) and drops the tokens. Called from the
    /// observer's `deinit` via a detached `Task`, since a `deinit` cannot `await` the actor directly.
    func removeObservers(from center: NotificationCenter) {
        if let resignObserver {
            center.removeObserver(resignObserver)
        }
        if let becomeActiveObserver {
            center.removeObserver(becomeActiveObserver)
        }
        resignObserver = nil
        becomeActiveObserver = nil
    }
}

/// Observes app-lifecycle transitions and drives durable background delivery of the queued tracking
/// batch (Story 5.3). On `willResignActive` it requests OS background time, persists the live buffer
/// to disk, enqueues a durable background `URLSession` upload of that file, then ends the background
/// task (AC1). On `didBecomeActive` it triggers a foreground-recovery flush so an undelivered batch a
/// prior session left on disk is delivered (AC6).
///
/// ── Why a `final class` registering in `init` (NOT an `actor` registering in `start()`) ──────────
/// Unlike `ConfigRefreshScheduler` (an `actor` whose observers are registered in `start()`), this
/// observer registers its two lifecycle observers SYNCHRONOUSLY in `init`. `NotificationCenter` does
/// NOT buffer (documented in `ConfigRefreshScheduler.swift`): a notification posted between
/// construction and any deferred registration is DROPPED. The supported usage (and the test) posts a
/// lifecycle notification immediately after constructing the observer, so registration must complete
/// before `init` returns. There are NO long-lived loops to cancel (only observer tokens to remove), so
/// teardown is the `deinit` alone — no `cancel()`/`start()` is needed (PLAT-4 wiring need only hold the
/// instance for its lifetime and drop it to tear down).
///
/// ── `Sendable` proof ─────────────────────────────────────────────────────────────────────────────
/// Every stored property is an immutable `let` of a `Sendable` type: ``engine`` (an `actor` holding
/// the collaborators + the mutable background-task id), ``tokens`` (an `actor` holding the
/// non-`Sendable` observer tokens), and ``notificationCenter``. The mutable / non-`Sendable` surface
/// lives entirely inside those two actors, so this class is an all-`let` `Sendable final class` with NO
/// `@unchecked Sendable` and NO `nonisolated(unsafe)` — mirroring `ConvertSDK`'s `Sendable` proof via
/// its `SchedulerBox`. (`Mutex` is not used — the SDK's deployment floor is iOS 15, below `Mutex`'s
/// iOS 18 availability.)
final class LifecycleObserver: Sendable {
    /// The side-effect engine the notification blocks hop into. An `actor` (`Sendable`), so the `let`
    /// keeps this class `Sendable` with no suppression.
    private let engine: LifecycleEngine
    /// Holds the two observer tokens for teardown. An `actor` (`Sendable`), so the `let` keeps this
    /// class `Sendable` with no suppression.
    private let tokens: LifecycleObserverTokens
    /// The center the two lifecycle observers watch. Injected (defaulting to `.default`) so each test
    /// wires an isolated `NotificationCenter()` and notifications never leak between parallel tests.
    private let notificationCenter: NotificationCenter

    /// Wires the observer to the queue, the background-upload seam, the queue-file URL, and the track
    /// endpoint, then registers the two lifecycle observers SYNCHRONOUSLY (so a notification posted
    /// immediately after construction is not dropped — see the type doc).
    ///
    /// - Parameters:
    ///   - eventQueue: The real event queue whose background-persist / foreground-recovery this drives.
    ///   - sessionManager: The durable background-upload seam (`enqueueUpload(fileURL:request:)`).
    ///   - queueFileURL: The on-disk batch file the durable upload streams from (production passes
    ///     `CoordinatedFileEventQueueStore.queueFileURL()`).
    ///   - trackEndpoint: The event-delivery base URL the upload request targets.
    ///   - notificationCenter: The center the observers watch; defaults to `.default`.
    init(
        eventQueue: EventQueue,
        sessionManager: any BackgroundUploadEnqueueing,
        queueFileURL: URL,
        trackEndpoint: String,
        notificationCenter: NotificationCenter = .default
    ) {
        self.notificationCenter = notificationCenter
        // Build the engine BEFORE registration so the observer blocks can capture IT (a `Sendable`
        // actor) rather than the not-yet-fully-initialized `self` (definite-initialization forbids
        // capturing `self` in an escaping closure until every stored property is set; the token
        // property cannot be set until registration returns the tokens — capturing the engine breaks
        // that cycle).
        let engine = LifecycleEngine(
            eventQueue: eventQueue,
            sessionManager: sessionManager,
            queueFileURL: queueFileURL,
            trackEndpoint: trackEndpoint
        )
        self.engine = engine

        // Register SYNCHRONOUSLY via the block-based `addObserver(forName:object:queue:using:)` (NOT
        // the async-sequence `notifications(named:)` form, which would drop a notification posted
        // before its first iteration — see the type doc). Each `@Sendable` block ignores the
        // (non-`Sendable`) `Notification`, captures only the `engine` actor, and spawns a fresh `Task`
        // that hops into the matching handler — the shortest path from delivery to effect, mirroring
        // `ConfigRefreshScheduler.start()`. `queue: nil` runs the block on the posting thread, which
        // only spawns a `Task`, so nothing non-`Sendable` crosses an isolation boundary.
        let resignObserver = notificationCenter.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await engine.handleBackground() }
        }
        let becomeActiveObserver = notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await engine.handleForeground() }
        }
        // Construction-time injection: the tokens are created in this nonisolated `init` and consumed
        // by the actor's nonisolated `init` in the same scope — no non-`Sendable` cross-isolation send.
        self.tokens = LifecycleObserverTokens(
            resignObserver: resignObserver,
            becomeActiveObserver: becomeActiveObserver
        )
    }

    /// Removes both lifecycle observers when the observer is released. `deinit` cannot `await`, so it
    /// hands off to a detached `Task` that captures only the (`Sendable`) ``tokens`` and the
    /// (`Sendable`) ``notificationCenter`` — never `self` — mirroring `ConvertSDK.deinit`'s handoff
    /// through its `Sendable` box. There are no long-lived loops to stop, so removing the observers is
    /// the whole of teardown.
    deinit {
        let tokens = self.tokens
        let center = self.notificationCenter
        Task { await tokens.removeObservers(from: center) }
    }
}
#endif
