// Tests/ConvertSDKTests/Adapters/BackgroundUploadDelegateTests.swift
import Testing
import Foundation
@testable import ConvertSDK

// RED phase (Epic 5, Story 5.3): this suite exercises `BackgroundUploadDelegate`, the
// `URLSession` delegate that reconciles a durable background upload against the on-disk event
// queue, which DOES NOT EXIST YET — the GREEN step creates it at
// `Sources/ConvertSDK/Adapters/BackgroundUploadDelegate.swift`. Until then this file fails to
// compile with "cannot find 'BackgroundUploadDelegate' in scope" (and "has no member
// 'handleCompletionForTesting'"), which is the expected RED state for this TDD cycle. Everything
// ELSE in this file — `StubURLSessionTask`, the `makeDelegate` / `makeTrackingEvent` builders, and
// the `MockEventQueueStore` it drives (in `MockPorts.swift`) — MUST compile.
//
// ── Contract under test (for the GREEN implementer) ───────────────────────────
// `final class BackgroundUploadDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate,
//  URLSessionDataDelegate, @unchecked Sendable` with:
//   * `init(store: any EventQueueStore, eventBus: EventBus,
//          completionHandlerProvider: @escaping () -> (() -> Void)?)`.
//   * On a 2xx upload outcome (a 2xx `HTTPURLResponse` on the task AND no transport error): calls
//     `store.clear()`, fires `.apiQueueReleased` on the bus, and invokes the stored completion
//     handler. The on-disk queue is cleared ONLY on this happy path.
//   * On a non-2xx HTTP response OR a transport error: does NOT call `store.clear()` — the on-disk
//     file is the durable record and must survive for the next launch to retry.
//   * `urlSessionDidFinishEvents(forBackgroundURLSession:)`: invokes the stored completion handler.
//   * `func handleCompletionForTesting(task: URLSessionTask, error: Error?) async` — runs the SAME
//     reconciliation logic as `urlSession(_:task:didCompleteWithError:)` but is AWAITABLE, so a
//     test can assert AFTER the async `store.clear()` has completed WITHOUT any `Task.sleep`
//     (NFR21 — no wall-clock waits).
//
// ── Why `StubURLSessionTask` takes the shape it does ──────────────────────────
// The reconciliation seam reads `task.response as? HTTPURLResponse` to classify the outcome, so a
// test needs a `URLSessionTask` whose `response` it controls. `URLSessionTask` has no public
// designated initializer — the only accessible one is `init()`, which Apple deprecated in iOS 13
// ("Not supported"). Subclassing and calling `super.init()` is the established test pattern and
// COMPILES under Swift 6 strict concurrency; it emits ONLY a cosmetic `#DeprecatedDeclaration`
// compiler warning (the package does NOT set `SWIFT_TREAT_WARNINGS_AS_ERRORS`, so the warning is
// non-fatal). Annotating the initializer `@available(*, deprecated)` was rejected: it relocates the
// warning to every call site (N warnings instead of the single one confined here).

/// A `URLSessionTask` test double whose ``response`` is a canned ``HTTPURLResponse`` of a chosen
/// status. The ONLY surface the reconciliation logic reads is `response`, so overriding it is
/// sufficient to drive every outcome branch (2xx / non-2xx / — paired with a transport error —
/// status `0`). `@unchecked Sendable` mirrors the production delegate's sanctioned carve-out: a
/// stub task is immutable after construction and only read, so the assertion is sound.
final class StubURLSessionTask: URLSessionTask, @unchecked Sendable {
    private let _response: URLResponse?

    /// Builds a stub whose ``response`` is an `HTTPURLResponse` with `status` for `url`.
    /// `super.init()` is the only accessible `URLSessionTask` initializer (deprecated-but-supported
    /// for this purpose); see the file header for why no warning-free alternative exists.
    init(status: Int, url: URL) {
        _response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        super.init()
    }

    override var response: URLResponse? { _response }
}

/// A one-shot continuation handoff a test awaits to learn that the background completion handler
/// ran — a genuine happens-before, with NO wall-clock wait (NFR21). The handler the SUT invokes may
/// hop to the main thread, so ``fire()`` is `actor`-isolated and tolerates arriving either before or
/// after ``awaitFired()`` parks: the park-or-resume decision is made on the actor (mirroring
/// `MockLogger.waitForEntry`), so the signal can never be missed and the continuation resumes once.
private actor CompletionSignal {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    /// Marks the handler as having run and resumes any parked ``awaitFired()``. Idempotent.
    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }

    /// Suspends until ``fire()`` has run. Returns immediately if it already did.
    func awaitFired() async {
        if fired { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if fired {
                cont.resume()
            } else {
                continuation = cont
            }
        }
    }
}

@Suite("BackgroundUploadDelegate")
struct BackgroundUploadDelegateTests {
    /// A stable URL for the stub tasks; the host is irrelevant — only the canned status drives the
    /// classification. Centralized so no case hardcodes its own literal.
    private static let endpoint = URL(string: "https://example.convert.com/track")!

    // MARK: - Shared builders (defined once, used everywhere — SonarQube new-code dup gate ≤ 3%)

    /// The single construction path for the SUT: wires it over `store`, a fresh ``EventBus``, and a
    /// `completionHandlerProvider` that always yields `completionHandler` (default: a no-op). Every
    /// case goes through here so the init call is never copy-pasted (SonarQube duplication gate).
    private func makeDelegate(
        store: MockEventQueueStore,
        completionHandler: @escaping () -> Void = {}
    ) -> BackgroundUploadDelegate {
        BackgroundUploadDelegate(
            store: store,
            eventBus: EventBus(),
            completionHandlerProvider: { completionHandler }
        )
    }

    /// Builds ONE ``TrackingEvent`` via the real initializers (a single bucketing entry under a
    /// single visitor) to seed the store with. Parameterized on `visitorId` so cases reuse it rather
    /// than re-instantiating the model — the duplication-safe way to stage a queued event.
    private func makeTrackingEvent(visitorId: String = "visitor-1") -> TrackingEvent {
        let entry = TrackingEventEntry.bucketing(
            BucketingEventData(experienceId: "exp-1", variationId: "var-1")
        )
        let visitor = Visitor(visitorId: visitorId, segments: ["country": "US"], events: [entry])
        return TrackingEvent(accountId: "acc-1", projectId: "proj-1", visitors: [visitor])
    }

    /// Seeds a fresh store with one event, runs the awaitable reconciliation seam for a stub task of
    /// `status` (+ optional `error`), and asserts the resulting ``clearCallCount``. The shared body
    /// behind the three outcome cases — they differ only in `(status, error, expected)`, so factoring
    /// it here keeps each `@Test` a single call (no near-identical blocks for SonarQube to flag).
    private func expectClearCount(
        status: Int,
        error: Error?,
        toBe expected: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let store = MockEventQueueStore()
        await store.seed([makeTrackingEvent()])
        let delegate = makeDelegate(store: store)

        let task = StubURLSessionTask(status: status, url: Self.endpoint)
        await delegate.handleCompletionForTesting(task: task, error: error)

        let count = await store.clearCallCount
        #expect(count == expected, sourceLocation: sourceLocation)
    }

    // MARK: - Cases

    /// A 2xx outcome (200, no transport error) clears the durable queue exactly once: the batch was
    /// accepted by the server, so the on-disk record is no longer needed. Asserted AFTER the async
    /// `store.clear()` via the awaitable seam — no `Task.sleep`.
    @Test("a 2xx upload outcome clears the queue store exactly once")
    func clearsQueueOnSuccess() async {
        await expectClearCount(status: 200, error: nil, toBe: 1)
    }

    /// A non-2xx outcome (500, no transport error) leaves the durable queue intact: the on-disk file
    /// is the retry record, so it must NOT be cleared after a server-side failure.
    @Test("a non-2xx upload outcome leaves the queue store intact (no clear)")
    func keepsQueueOnServerError() async {
        await expectClearCount(status: 500, error: nil, toBe: 0)
    }

    /// A transport error (no usable HTTP response) leaves the durable queue intact: the request never
    /// reached a 2xx, so the on-disk file must survive for the next launch to retry.
    @Test("a transport error leaves the queue store intact (no clear)")
    func keepsQueueOnTransportError() async {
        await expectClearCount(status: 0, error: URLError(.networkConnectionLost), toBe: 0)
    }

    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` invokes the stored background completion
    /// handler — the system's signal that all events for the background session have been delivered,
    /// which the app must acknowledge by calling the saved handler. The wait is a continuation handoff
    /// (the handler resumes ``CompletionSignal``), so it is deterministic with NO wall-clock wait even
    /// if the handler hops to the main thread.
    @Test("urlSessionDidFinishEvents invokes the stored background completion handler")
    func finishEventsInvokesCompletionHandler() async {
        let signal = CompletionSignal()
        let delegate = makeDelegate(store: MockEventQueueStore()) {
            Task { await signal.fire() }
        }

        delegate.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession(configuration: .default))

        await signal.awaitFired()
    }
}
