// MockEventQueueStore.swift
// The `EventQueueStore` test double for the PLATFORM target (`ConvertSDKTests`). It is a sibling
// support file — NOT appended to `MockPorts.swift` — because adding it there would push that file
// over SwiftLint's 400-line `file_length` limit; this mirrors how `MockClock.swift` was extracted
// from `MockPorts.swift` for the same reason. Being an `actor`, it depends on NOTHING in
// `MockPorts.swift` (no `LockedBox`) — only on the `EventQueueStore` port and the `TrackingEvent`
// model, both re-exported through `ConvertSDK`.
//
// An identical double lives in `ConvertSDKCoreTests/Support/MockCorePorts.swift`, but the two test
// targets cannot share support code: `ConvertSDKTests` cannot see `ConvertSDKCoreTests`' types (and
// vice versa), for the same target-visibility reason the Core copy documents. The suite that drives
// THIS copy — `BackgroundUploadDelegateTests` — lives in this target.

import Foundation
import ConvertSDK

// MARK: - MockEventQueueStore

/// Test double for ``EventQueueStore`` (the durable pending-event-queue persistence port).
///
/// Shape: `actor` — `load`/`persist`/`clear` are all `async throws`, so actor isolation satisfies
/// the port with NO `Sendable` suppression (matching the `actor` mocks in `MockPorts.swift`; unlike
/// the synchronous mocks there that need ``LockedBox``). It models disk as one in-memory
/// ``storedEvents`` cell: ``persist(_:)`` overwrites it, ``clear()`` empties it, ``load()`` returns
/// it — so a test can assert BOTH how many times each side effect fired (the three call counters)
/// and WHAT currently sits "on disk" (``storedEvents``).
///
/// ── `seed(_:)` helper ─────────────────────────────────────────────────────────────────────────
/// Pre-populates ``storedEvents`` WITHOUT bumping ``persistCallCount`` — it stages the cold-start /
/// disk-first fixture the way a prior process would have left the queue file, so the counters still
/// reflect only the calls the SUBJECT made during the test (a `persist` would conflate fixture setup
/// with subject behavior). It is an `actor`-isolated method, so a test awaits it before the action.
///
/// ── `waitForPersistCount(_:)` helper (Story 5.3 lifecycle RED) ─────────────────────────────────
/// The Story-5.3 `LifecycleObserver` AC1 test needs a genuine happens-before on "the observer's
/// background-transition handler called the queue's `persistBeforeBackground()`, which wrote the
/// store" — that persist runs on a detached `Task` the notification observer's block spawns, which
/// the test does not await directly. ``waitForPersistCount(_:)`` parks a continuation that
/// ``persist(_:)`` resumes the instant the Nth persist lands — a pure continuation handoff, no
/// wall-clock wait (NFR21) — mirroring `MockEventUploader.waitForBatchCount` /
/// `MockConfigFetchService.waitForFetchCount`. Additive: the existing `BackgroundUploadDelegate` /
/// `CoordinatedFileEventQueueStore` suites that use this double are unaffected (no existing signature
/// changes).
actor MockEventQueueStore: EventQueueStore {
    /// One awaiter parked by ``waitForPersistCount(_:)``, keyed to the persist-count THRESHOLD it
    /// waits for. A named struct keeps the `large_tuple` lint rule satisfied.
    private struct PersistAwaiter {
        let threshold: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    /// The events currently "on disk": set by ``persist(_:)`` / ``seed(_:)``, emptied by ``clear()``,
    /// returned by ``load()``. A test reads it to confirm a side effect landed (or didn't).
    private(set) var storedEvents: [TrackingEvent] = []
    /// Number of times ``load()`` was invoked.
    private(set) var loadCallCount = 0
    /// Number of times ``persist(_:)`` was invoked.
    private(set) var persistCallCount = 0
    /// Number of times ``clear()`` was invoked — the 2xx-upload-clears-the-queue signal under test.
    private(set) var clearCallCount = 0
    private var persistAwaiters: [PersistAwaiter] = []

    func load() async throws -> [TrackingEvent] {
        loadCallCount += 1
        return storedEvents
    }

    func persist(_ events: [TrackingEvent]) async throws {
        persistCallCount += 1
        storedEvents = events
        // Resume (and drop) every awaiter whose threshold the new count has now reached. Actor
        // isolation is the mutual exclusion; each awaiter is removed as collected, so it resumes once.
        let ready = persistAwaiters.filter { $0.threshold <= persistCallCount }
        persistAwaiters.removeAll { $0.threshold <= persistCallCount }
        for awaiter in ready {
            awaiter.continuation.resume()
        }
    }

    /// Suspends until ``persist(_:)`` has been called at least `target` times, then resumes — a
    /// genuine happens-before on "the Nth persist has run". Returns immediately if the count is already
    /// ≥ `target`; otherwise parks a continuation keyed to that threshold, which ``persist(_:)``
    /// resumes the moment the count reaches it. Pure continuation handoff — no wall-clock wait (NFR21).
    func waitForPersistCount(_ target: Int) async {
        if persistCallCount >= target { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            persistAwaiters.append(PersistAwaiter(threshold: target, continuation: continuation))
        }
    }

    func clear() async throws {
        clearCallCount += 1
        storedEvents = []
    }

    /// Pre-populates ``storedEvents`` for a cold-start / disk-first fixture WITHOUT counting as a
    /// ``persist(_:)`` — so the counters reflect only the subject's calls, not fixture setup.
    func seed(_ events: [TrackingEvent]) {
        storedEvents = events
    }

    // MARK: - Background-upload in-flight marker (Story 5.3 / F-052 — cross-path exactly-once)

    /// Models the on-disk in-flight marker's presence: staged via ``seedInFlight(_:)`` or set/cleared by
    /// the subject through the three port methods below. A test reads it to confirm the marker's state.
    private(set) var inFlight = false
    /// Number of times ``markBackgroundUploadInFlight()`` was invoked.
    private(set) var markInFlightCallCount = 0
    /// Number of times ``clearBackgroundUploadInFlight()`` was invoked — the reconcile-releases-marker signal.
    private(set) var clearInFlightCallCount = 0

    func markBackgroundUploadInFlight() async throws {
        markInFlightCallCount += 1
        inFlight = true
    }

    func clearBackgroundUploadInFlight() async throws {
        clearInFlightCallCount += 1
        inFlight = false
    }

    func isBackgroundUploadInFlight() async throws -> Bool {
        inFlight
    }

    /// Stages the in-flight marker WITHOUT bumping ``markInFlightCallCount`` — fixture setup (mirrors
    /// ``seed(_:)``), so the counters reflect only the subject's own calls.
    func seedInFlight(_ value: Bool) {
        inFlight = value
    }
}
