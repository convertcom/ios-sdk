// BackgroundUploadDelegate.swift
// `URLSession` delegate (Epic 5 / Story 5.3) that reconciles a durable BACKGROUND upload against
// the on-disk event queue. Lives in the `ConvertSwiftSDK` target because it composes the
// URLSession-backed background transport; the ports it drives (``EventQueueStore``) and the bus it
// fires on (``EventBus``) are Foundation-only and live in the pure-logic `ConvertSwiftSDKCore`.

import ConvertSwiftSDKCore
import Foundation

/// Reconciles the outcome of a durable background `URLSession` upload against the durable on-disk
/// event queue, and acknowledges the system's background-session completion handoff.
///
/// Lifecycle the delegate closes (per Story 5.3):
/// - On a **2xx** upload outcome (a 2xx `HTTPURLResponse` on the task AND no transport error) the
///   batch was accepted by the server, so the durable on-disk queue is cleared exactly once and an
///   ``SystemEvent/apiQueueReleased`` event is fired (carrying the delivered batch's event count).
///   The stored background completion handler is NOT invoked on this per-task outcome — see the
///   `urlSessionDidFinishEvents` bullet below for why it fires once from there per Apple's contract.
/// - On a **non-2xx** HTTP response OR a **transport error** the durable on-disk file is the retry
///   record and MUST survive for the next launch: the queue is left intact (no `clear()`).
/// - On `urlSessionDidFinishEvents(forBackgroundURLSession:)` (the system's signal that all events
///   for the background session have been delivered) the stored completion handler is invoked.
///
/// Concurrency shape — the ONE sanctioned `@unchecked Sendable` carve-out (architecture.md
/// §Process Patterns): `URLSessionDelegate` conformance requires an `NSObject`, and its callbacks
/// arrive on the session's serial delegate queue, so an `actor` cannot satisfy the protocol. This
/// type is therefore a `final class … @unchecked Sendable`. The suppression is sound because every
/// stored property is an immutable `let` set at `init` (no per-task mutable state — the upload's
/// final response is read directly off `task.response`), and ALL queue mutation is confined to
/// actor-dispatched ``EventQueueStore`` operations (`load`/`clear`), never to fields on this class.
/// This is the only suppression in the file; everything else is compiler-proven `Sendable`.
final class BackgroundUploadDelegate:
    NSObject,
    URLSessionDelegate,
    URLSessionTaskDelegate,
    URLSessionDataDelegate,
    @unchecked Sendable {
    /// The durable pending-event-queue persistence port (load to count, clear on success).
    private let store: any EventQueueStore
    /// The in-process bus the delivered-batch (`apiQueueReleased`) event is fired on.
    private let eventBus: EventBus
    /// Yields the saved background completion handler to invoke once the session's work is
    /// acknowledged; returns `nil` when no handler is currently registered.
    private let completionHandlerProvider: () -> (() -> Void)?

    /// Wires the delegate to its durable store, event bus, and completion-handler source.
    ///
    /// - Parameters:
    ///   - store: The durable pending-event-queue persistence port.
    ///   - eventBus: The in-process bus the `apiQueueReleased` event is fired on.
    ///   - completionHandlerProvider: Yields the saved background completion handler (or `nil`).
    init(
        store: any EventQueueStore,
        eventBus: EventBus,
        completionHandlerProvider: @escaping () -> (() -> Void)?
    ) {
        self.store = store
        self.eventBus = eventBus
        self.completionHandlerProvider = completionHandlerProvider
    }

    /// `URLSession` callback for a completed task: schedules the awaitable reconciliation. Arrives on
    /// the session's serial delegate queue; the actual work hops onto a `Task` so the `async` store
    /// operations can be awaited without blocking the delegate queue.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { await self.reconcile(task: task, error: error) }
    }

    /// Testing seam: runs the SAME reconciliation as `urlSession(_:task:didCompleteWithError:)` but
    /// is `await`-able, so a test can assert AFTER the async `store.clear()` has completed WITHOUT any
    /// `Task.sleep` (NFR21 — no wall-clock waits).
    func handleCompletionForTesting(task: URLSessionTask, error: Error?) async {
        await reconcile(task: task, error: error)
    }

    /// `URLSession` callback signalling all events for the background session have been delivered:
    /// invokes the stored background completion handler so the app can acknowledge the handoff.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        completionHandlerProvider()?()
    }

    /// Classifies the upload outcome from `task.response` / `error` and drives the durable-queue
    /// lifecycle. Called exactly once per task completion; each outcome (transport-error / non-2xx /
    /// 2xx) is a single exit, so no side effect can double-fire.
    private func reconcile(task: URLSessionTask, error: Error?) async {
        // The background upload has now been reconciled (success OR failure), so it is no longer
        // outstanding: clear the in-flight marker FIRST, on EVERY exit, so the foreground-recovery flush
        // / cold-start recovery may once again own the on-disk queue file (cross-path exactly-once —
        // Story 5.3 / F-052). Cleared BEFORE the early returns below so a non-2xx / transport-error
        // outcome — which intentionally LEAVES the queue file as the retry record — still releases the
        // marker, letting the next flush / cold start recover that file exactly once.
        try? await store.clearBackgroundUploadInFlight()

        // Transport error: the request never reached a 2xx, so the on-disk file is the durable retry
        // record and must survive — do NOT clear.
        if error != nil { return }

        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        // Non-2xx (incl. a missing/unusable HTTP response → status 0): server-side failure; the
        // on-disk file is the retry record — do NOT clear.
        guard (200..<300).contains(status) else { return }

        // 2xx happy path: count the delivered events, clear the durable queue exactly once, and
        // announce the released batch.
        let events = (try? await store.load()) ?? []
        let eventCount = events.reduce(0) { partial, event in
            partial + event.visitors.reduce(0) { $0 + $1.events.count }
        }
        try? await store.clear()
        await eventBus.fire(
            .apiQueueReleased,
            payload: .apiQueueReleased(ApiQueueReleasedPayload(eventCount: eventCount))
        )
        // The background completion handler is intentionally NOT called here. Per Apple's background-
        // `URLSession` contract (Story 5.3 AC5) the saved handler must be invoked exactly once, from
        // `urlSessionDidFinishEvents(forBackgroundURLSession:)`, AFTER all session events are delivered
        // — not on this per-task `didCompleteWithError` outcome. Calling it here too would double-fire
        // it (once before all events are processed, once after), violating the contract.
    }
}
