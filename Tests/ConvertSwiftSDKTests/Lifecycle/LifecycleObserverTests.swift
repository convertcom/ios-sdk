// Tests/ConvertSwiftSDKTests/Lifecycle/LifecycleObserverTests.swift
//
// RED-phase contract for `LifecycleObserver` (Epic 5 / Story 3 — durable background `URLSession`
// delivery on app lifecycle). The class does NOT exist yet — the GREEN step creates it at
// `Sources/ConvertSwiftSDK/Lifecycle/LifecycleObserver.swift`. Every reference here goes through the
// `makeLifecycleObserver(...)` factory, whose return type names `LifecycleObserver`, so this whole
// suite fails to compile with "cannot find type 'LifecycleObserver' in scope" (plus the seam
// protocol `BackgroundUploadEnqueueing` the mock conforms to) until GREEN — the expected RED state.
//
// ── Expected RED-missing PRODUCTION symbols (everything else compiles) ──────────────────────────
//   * `LifecycleObserver`            — the class under test (created in GREEN).
//   * `BackgroundUploadEnqueueing`   — the background-upload SEAM protocol (declared in GREEN on
//                                      `BackgroundSessionManager.swift`); `MockBackgroundSessionManager`
//                                      conforms to it, so it is also missing until GREEN.
// Both are PRODUCTION types this task introduces. Every test double / helper compiles against
// EXISTING types (`EventQueue`, `MockEventQueueStore`, `MockEventUploader`, `EventBus`,
// `NotificationCenter`, the model types).
//
// ── Mirrors the established lifecycle-observation pattern (ConfigRefreshScheduler) ──────────────
// `LifecycleObserver` MUST observe app-lifecycle notifications via the SYNCHRONOUS, block-based
// `notificationCenter.addObserver(forName:object:queue:using:)` and take an INJECTED
// `notificationCenter: NotificationCenter` (defaulting to `.default`) — NOT the async-sequence
// `notifications(named:)` form, which drops notifications posted before the observing Task's first
// iteration (documented in `ConfigRefreshScheduler.swift`). These tests inject a FRESH isolated
// `NotificationCenter()` per SUT, post `UIApplication` lifecycle notifications to THAT center, and
// await the effect via a continuation-based happens-before (the mock uploader's / session manager's
// `waitFor…Count`) — NEVER `Task.sleep`, NEVER a wall-clock wait (NFR21).
//
// ── The two side effects under test, observed via the seam + a real EventQueue ─────────────────
// AC1 (willResignActive): the observer requests OS background time, calls the queue's
//   `persistBeforeBackground()`, enqueues a durable background upload via the session-manager seam,
//   then ends the background task. Observed as: the queue's `MockEventQueueStore.persistCallCount`
//   incremented (the real `EventQueue.persistBeforeBackground()` calls `store.persist`) AND the
//   `MockBackgroundSessionManager.enqueueUploadCallCount` incremented.
// AC6 (didBecomeActive): the observer triggers a foreground-recovery flush. Observed as: a store
//   pre-seeded with an undelivered prior-session event gets DELIVERED through the `MockEventUploader`
//   (its recorded batches become non-empty, carrying the seeded visitor).
//
// ── GREEN-phase production change this RED suite REQUIRES (see report) ──────────────────────────
// `EventQueue.flush()` is `private` and `persistBeforeBackground()` is `internal` to ConvertSwiftSDKCore
// — NEITHER is reachable from the `ConvertSwiftSDK` target where the observer lives. So these tests assert
// the OBSERVABLE effects (store persist count; uploader delivery) rather than calling those methods,
// and the GREEN implementer MUST expose a cross-target-reachable entry point (e.g. make
// `persistBeforeBackground()` and a foreground-recovery flush `public`/`package`) for the observer to
// drive. The tests are written to that observable contract and do not presuppose the access change.
import Testing
import Foundation
@testable import ConvertSwiftSDK
#if canImport(UIKit)
import UIKit
#endif

// The whole suite is gated on UIKit: `LifecycleObserver` observes `UIApplication.willResignActive` /
// `didBecomeActive`, which exist only where UIKit is available (the CI host is the iOS Simulator). On
// a pure-macOS host those notification names are absent and the lifecycle contract is out of scope.
#if canImport(UIKit)
@Suite("LifecycleObserver")
struct LifecycleObserverTests {
    // MARK: Shared identity constants (one source so cases read by intent, not re-spelled literals)

    /// The account/project the real `EventQueue` stamps onto every assembled envelope. Declared once
    /// so the harness wiring and the seeded fixture agree without re-spelling (SonarQube 3% gate).
    private static let accountId = "acc-lifecycle"
    private static let projectId = "proj-lifecycle"

    // MARK: SUT factory + harness

    /// The fully-wired `LifecycleObserver` system-under-test plus every collaborator a test drives or
    /// observes. A named struct (not a large tuple) keeps the `large_tuple` lint rule satisfied and
    /// lets tests read collaborators by name. `Sendable` — every member is `Sendable` (the observer,
    /// three actors, a `NotificationCenter`, a `URL`).
    struct ObserverSUT: Sendable {
        /// The system under test (does not exist until GREEN — this is the RED-making reference).
        let observer: LifecycleObserver
        /// The REAL event queue the observer drives — built over `store` + `uploader` so its
        /// background-persist and foreground-recovery effects are observable through those doubles.
        let queue: EventQueue
        /// The durable-queue store double; read `persistCallCount` to assert the background persist ran.
        let store: MockEventQueueStore
        /// The upload double the queue's recovery flush delivers through; read `uploadedBatches()` to
        /// assert a seeded prior-session event was delivered on foreground.
        let uploader: MockEventUploader
        /// The background-upload seam double; read `enqueueUploadCallCount` to assert the observer
        /// enqueued the durable background upload on a background transition.
        let sessionManager: MockBackgroundSessionManager
        /// The FRESH notification center the observer observes; post `UIApplication` lifecycle
        /// notifications here to drive the observers in isolation (never leaking to parallel tests).
        let center: NotificationCenter
    }

    /// Builds a `LifecycleObserver` SUT wired to a REAL `EventQueue` (over recording doubles), the
    /// background-upload seam double, an isolated `NotificationCenter()`, a temp queue-file URL, and a
    /// track endpoint — the SINGLE construction path for the whole suite (SonarQube CPD is token-based,
    /// so sharing this block, not renaming locals, is what holds the diff under the 3% gate).
    ///
    /// `async` only because seeding the store (the AC6 prior-session fixture) is `actor`-isolated and
    /// awaited here; the await is fixture setup, NOT a wall-clock wait (NFR21). `seedStored` pre-seeds
    /// the store WITHOUT bumping `persistCallCount` (so the AC1 count reflects only the observer's
    /// persist), staging the undelivered prior-session event the AC6 recovery flush must deliver.
    ///
    /// - Parameters:
    ///   - seedStored: events to stage on disk as a prior session would have left them (AC6 fixture);
    ///     empty (the default) leaves a clean queue for the AC1 background-persist case.
    ///   - queueFileURL: the on-disk batch file the observer uploads from (any isolated temp URL in
    ///     tests; production passes `CoordinatedFileEventQueueStore.queueFileURL()`).
    ///   - trackEndpoint: the event-delivery base URL the observer builds its upload request against.
    private func makeLifecycleObserver(
        seedStored: [TrackingEvent] = [],
        queueFileURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-\(UUID().uuidString).json"),
        trackEndpoint: String = "https://example.invalid"
    ) async -> ObserverSUT {
        let store = MockEventQueueStore()
        if !seedStored.isEmpty {
            await store.seed(seedStored)
        }
        let uploader = MockEventUploader()
        let bus = EventBus()
        // batchSize 100 keeps any below-threshold enqueue from auto-flushing and racing the
        // observer-driven effects; the queue stamps the shared account/project onto its envelopes.
        let queue = EventQueue(
            accountId: Self.accountId,
            projectId: Self.projectId,
            batchSize: 100,
            uploader: uploader,
            eventBus: bus,
            store: store
        )
        let sessionManager = MockBackgroundSessionManager()
        let center = NotificationCenter()
        let observer = LifecycleObserver(
            eventQueue: queue,
            sessionManager: sessionManager,
            queueFileURL: queueFileURL,
            trackEndpoint: trackEndpoint,
            notificationCenter: center
        )
        return ObserverSUT(
            observer: observer,
            queue: queue,
            store: store,
            uploader: uploader,
            sessionManager: sessionManager,
            center: center
        )
    }

    /// One bucketing event envelope for `visitorId`, shaped the way a prior process would have left it
    /// in the queue file — the AC6 undelivered-prior-session fixture. Single owner of the seed-envelope
    /// construction (account/project mirror the harness defaults so a loaded envelope is
    /// indistinguishable from one the queue itself would assemble).
    private static func storedEvent(visitorId: String) -> TrackingEvent {
        TrackingEvent(
            accountId: accountId,
            projectId: projectId,
            visitors: [
                Visitor(
                    visitorId: visitorId,
                    segments: [:],
                    events: [.bucketing(BucketingEventData(experienceId: "exp1", variationId: "var1"))]
                )
            ]
        )
    }

    /// Posts `UIApplication.willResignActiveNotification` to `center`, driving the observer's
    /// background-transition handler. Single owner of the post so neither case re-spells the name.
    private func triggerResignActive(center: NotificationCenter) {
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
    }

    /// Posts `UIApplication.didBecomeActiveNotification` to `center`, driving the observer's
    /// foreground-recovery handler. Single owner of the post so neither case re-spells the name.
    private func triggerBecomeActive(center: NotificationCenter) {
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: Scenario 1 — willResignActive persists the buffer and enqueues a background upload (AC1)

    /// AC1: on `willResignActive`, the observer requests OS background time, calls the queue's
    /// `persistBeforeBackground()` (which persists the live buffer to the store), then enqueues a
    /// durable background upload via the session-manager seam, then ends the background task.
    ///
    /// Driven by enqueuing ONE below-threshold bucketing event on the REAL queue (so it sits in the
    /// in-memory buffer, un-flushed), posting `willResignActive` to the INJECTED center, then awaiting
    /// BOTH observable effects via genuine happens-befores (no `Task.sleep`, no poll): the store's
    /// `persistCallCount` reaching 1 (proving `persistBeforeBackground()` ran and wrote the buffer) and
    /// the session manager's `enqueueUploadCallCount` reaching 1 (proving the durable upload was
    /// enqueued). The two waits ORDER the two assertions on the observer's async background handler.
    @Test("willResignActive persists the buffer and enqueues a background upload")
    func resignActivePersistsBufferAndEnqueuesUpload() async {
        let sut = await makeLifecycleObserver()
        // A single below-threshold enqueue: it stays in the buffer (batchSize 100), so the observer's
        // persistBeforeBackground() has something to move to disk — and nothing auto-flushes first.
        await sut.queue.enqueue(
            .bucketing(BucketingEventData(experienceId: "exp1", variationId: "var1")),
            for: "v1",
            segments: nil
        )

        triggerResignActive(center: sut.center)

        // Await the persist landing AND the background upload being enqueued — both real
        // happens-befores the doubles' continuations resume, not bounded polls. Awaiting each before
        // its assertion orders the observer's async background work against the reads.
        await sut.store.waitForPersistCount(1)
        await sut.sessionManager.waitForEnqueueCount(1)

        #expect(await sut.store.persistCallCount >= 1)
        #expect(await sut.sessionManager.enqueueUploadCallCount >= 1)
        // The durable upload streams from the queue FILE URL the observer was handed (not a hardcoded
        // path) — so the enqueued upload targets the persisted batch file.
        #expect(await sut.sessionManager.lastUploadFileURL != nil)
    }

    // MARK: Scenario 2 — didBecomeActive triggers a foreground recovery flush (AC6)

    /// AC6: on `didBecomeActive`, the observer triggers a foreground-recovery flush of the queue, so an
    /// undelivered batch left on disk by a prior session is delivered.
    ///
    /// The store is PRE-SEEDED (via the harness) with one prior-session event for "v-prior" (staged
    /// without bumping `persistCallCount`). Posting `didBecomeActive` to the INJECTED center must drive
    /// the recovery flush, which delivers that batch THROUGH the real queue's uploader. The test awaits
    /// the uploader recording its first batch via a genuine happens-before (`waitForBatchCount(1)` — a
    /// continuation the uploader resumes, not a `Task.sleep`/poll), then asserts the delivered batch
    /// carries the seeded visitor — proving the prior-session event was recovered and delivered.
    ///
    /// (This is the observable form of the AC6 contract: the queue's recovery `flush()` is `private`
    /// and not reachable cross-target, so the test asserts DELIVERY through the uploader rather than
    /// calling a flush method. The GREEN implementer exposes a reachable recovery entry point — see the
    /// suite header's GREEN-phase note.)
    @Test("didBecomeActive triggers a foreground recovery flush")
    func becomeActiveTriggersForegroundRecoveryFlush() async {
        let sut = await makeLifecycleObserver(seedStored: [Self.storedEvent(visitorId: "v-prior")])

        triggerBecomeActive(center: sut.center)

        // Await the recovery delivery — a real event (the uploader's continuation resumes on the first
        // recorded batch), not a settled-by-timeout poll.
        await sut.uploader.waitForBatchCount(1)

        // `uploadedBatches()` is `[[TrackingEvent]]` (one inner array per upload call); flatten the
        // batches to envelopes, then envelopes to visitors, to read the delivered visitor ids.
        let delivered = await sut.uploader.uploadedBatches()
        let visitorIds = delivered.flatMap { $0 }.flatMap(\.visitors).map(\.visitorId)
        #expect(visitorIds.contains("v-prior"))
    }
}
#endif
