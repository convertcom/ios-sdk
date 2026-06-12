// MockBackgroundDelivery.swift
// Test doubles for the Story 5.3 `LifecycleObserver` RED suite that the PLATFORM target
// (`ConvertSDKTests`) needs but does not yet have: the background-upload seam double
// (`MockBackgroundSessionManager`) and an `EventUploader` double (`MockEventUploader`) for
// driving a REAL `EventQueue` from this target.
//
// ── Why a SEPARATE support file (not appended to MockPorts.swift) ───────────────────────────────
// `MockPorts.swift` sits at 397 lines — three under SwiftLint's 400-line `file_length` limit.
// Appending these two mocks would push it over, so they live in this sibling file, mirroring how
// `MockClock.swift` and `MockEventQueueStore.swift` were extracted from `MockPorts.swift` for the
// SAME reason. Both mocks are `actor`s, so neither depends on `MockPorts.swift`'s `LockedBox` — they
// reference only the production ports (`EventUploader`, re-exported through `ConvertSDK`) and the
// to-be-built `BackgroundUploadEnqueueing` seam.
//
// ── Target-visibility note ──────────────────────────────────────────────────────────────────────
// A `MockEventUploader` already exists in `ConvertSDKCoreTests/Support/MockCorePorts.swift`, but the
// two test targets cannot share support code: `ConvertSDKTests` cannot see `ConvertSDKCoreTests`'
// types (and vice versa), for the same target-visibility reason `MockEventQueueStore.swift`
// documents. The suite that drives THESE doubles — `LifecycleObserverTests` — lives in this target,
// and this target has no `EventUploader` double until now, so one is declared here.
//
// ── RED-missing symbol ──────────────────────────────────────────────────────────────────────────
// `BackgroundUploadEnqueueing` (the seam `MockBackgroundSessionManager` conforms to) is a PRODUCTION
// type the GREEN step declares on `BackgroundSessionManager.swift`; until then this conformance is an
// expected RED-missing symbol, alongside `LifecycleObserver` itself. Every OTHER symbol here compiles
// against existing types.

import Foundation
import ConvertSDK

// MARK: - MockEventUploader

/// Test double for ``EventUploader`` (the tracking-event upload port a real ``EventQueue`` ships
/// batches through) for the PLATFORM target. The `LifecycleObserver` AC6 test drives a real
/// `EventQueue` over a ``MockEventQueueStore`` and observes recovery delivery THROUGH this uploader —
/// so the queue's foreground-recovery flush is observable without reaching the queue's `private`
/// `flush()`.
///
/// Shape: `actor` — `upload(_:)` is `async throws`, so actor isolation satisfies the port with NO
/// `Sendable` suppression (matching the `actor` mocks in `MockPorts.swift`; unlike the synchronous
/// mocks there that need `LockedBox`). Each call appends the batch it received, so a test can assert
/// HOW MANY uploads happened (``callCount``) and WHAT each carried (``uploadedBatches()``).
///
/// ── `waitForBatchCount(_:)` — deterministic happens-before (NFR21) ──────────────────────────────
/// The recovery delivery runs on a `Task` the notification observer's block spawns, which the test
/// does not await directly. Rather than poll-and-hope, ``waitForBatchCount(_:)`` parks a continuation
/// that ``upload(_:)`` resumes the instant the Nth batch is recorded — a pure continuation handoff,
/// no wall-clock wait — mirroring `MockConfigFetchService.waitForFetchCount` / `MockLogger.waitForEntry`.
actor MockEventUploader: EventUploader {
    /// One awaiter parked by ``waitForBatchCount(_:)``, keyed to the batch-count THRESHOLD it waits
    /// for. ``upload(_:)`` resumes (and removes) every awaiter whose threshold the new count reaches.
    /// A named struct keeps the `large_tuple` lint rule satisfied.
    private struct BatchAwaiter {
        let threshold: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var batches: [[TrackingEvent]] = []
    private var batchAwaiters: [BatchAwaiter] = []

    /// Number of times ``upload(_:)`` was invoked.
    var callCount: Int { batches.count }

    /// The batches passed to each ``upload(_:)`` call, in call order.
    func uploadedBatches() -> [[TrackingEvent]] {
        batches
    }

    /// Suspends until ``upload(_:)`` has recorded at least `target` batches, then resumes — a genuine
    /// happens-before on "the Nth upload has run", replacing a bounded poll that would race the
    /// detached recovery `Task`. Returns immediately if the count is already ≥ `target`; otherwise
    /// parks a continuation keyed to that threshold, which ``upload(_:)`` resumes the moment the count
    /// reaches it. A pure continuation handoff — no wall-clock wait (NFR21).
    func waitForBatchCount(_ target: Int) async {
        if batches.count >= target { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            batchAwaiters.append(BatchAwaiter(threshold: target, continuation: continuation))
        }
    }

    func upload(_ events: [TrackingEvent]) async throws {
        batches.append(events)
        // Resume (and drop) every awaiter whose threshold the new count has now reached. Actor
        // isolation is the mutual exclusion, so the continuations resume directly; each is removed as
        // it is collected, so it resumes exactly once.
        let ready = batchAwaiters.filter { $0.threshold <= batches.count }
        batchAwaiters.removeAll { $0.threshold <= batches.count }
        for awaiter in ready {
            awaiter.continuation.resume()
        }
    }
}

// MARK: - MockBackgroundSessionManager

/// Test double for the background-upload seam ``BackgroundUploadEnqueueing`` (the protocol the real
/// `BackgroundSessionManager` conforms to in GREEN, mirroring how `ConfigRefreshScheduler` depends on
/// `any ConfigProviding`). `LifecycleObserver` holds `any BackgroundUploadEnqueueing` and calls
/// ``enqueueUpload(fileURL:request:)`` on a background transition; this double records that call so
/// the AC1 test can assert the observer enqueued the durable upload WITHOUT a real background
/// `URLSession`.
///
/// Shape: `actor` — the seam's `enqueueUpload(fileURL:request:)` is synchronous in PRODUCTION (the
/// real manager just builds and `resume()`s a task), but recording it as an `actor` lets the mock be
/// `Sendable` with NO suppression and gives the AC1 test an awaitable ``waitForEnqueueCount(_:)``
/// happens-before. The observer therefore calls it as `await sessionManager.enqueueUpload(...)`; the
/// `BackgroundUploadEnqueueing` requirement is declared `async` so an `actor` can satisfy it (the real
/// `BackgroundSessionManager`'s synchronous body trivially satisfies an `async` requirement).
///
/// ── `waitForEnqueueCount(_:)` — deterministic happens-before (NFR21) ────────────────────────────
/// The observer enqueues the upload from a `Task` its `willResignActive` block spawns, which the test
/// does not await directly. ``waitForEnqueueCount(_:)`` parks a continuation that ``enqueueUpload``
/// resumes the instant the Nth call lands — a pure continuation handoff, no wall-clock wait — so the
/// AC1 assertion is deterministic.
actor MockBackgroundSessionManager: BackgroundUploadEnqueueing {
    /// One awaiter parked by ``waitForEnqueueCount(_:)``, keyed to the enqueue-count THRESHOLD it
    /// waits for. A named struct keeps the `large_tuple` lint rule satisfied.
    private struct EnqueueAwaiter {
        let threshold: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    /// Number of times ``enqueueUpload(fileURL:request:)`` was invoked — the AC1 "observer enqueued a
    /// background upload" signal.
    private(set) var enqueueUploadCallCount = 0
    /// The `fileURL` of the LAST enqueued upload, so a test can assert the observer uploaded from the
    /// queue file URL it was handed (not a hardcoded path).
    private(set) var lastUploadFileURL: URL?
    /// The `request` of the LAST enqueued upload, so a test can assert the upload request shape.
    private(set) var lastUploadRequest: URLRequest?
    private var enqueueAwaiters: [EnqueueAwaiter] = []

    /// Suspends until ``enqueueUpload(fileURL:request:)`` has been called at least `target` times,
    /// then resumes — a genuine happens-before on "the Nth enqueue has run". Returns immediately if
    /// the count is already ≥ `target`; otherwise parks a continuation keyed to that threshold, which
    /// ``enqueueUpload(fileURL:request:)`` resumes the moment the count reaches it. Pure continuation
    /// handoff — no wall-clock wait (NFR21).
    func waitForEnqueueCount(_ target: Int) async {
        if enqueueUploadCallCount >= target { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueueAwaiters.append(EnqueueAwaiter(threshold: target, continuation: continuation))
        }
    }

    func enqueueUpload(fileURL: URL, request: URLRequest) async {
        enqueueUploadCallCount += 1
        lastUploadFileURL = fileURL
        lastUploadRequest = request
        // Resume (and drop) every awaiter whose threshold the new count reached. Actor isolation is
        // the mutual exclusion; each awaiter is removed as collected, so it resumes exactly once.
        let ready = enqueueAwaiters.filter { $0.threshold <= enqueueUploadCallCount }
        enqueueAwaiters.removeAll { $0.threshold <= enqueueUploadCallCount }
        for awaiter in ready {
            awaiter.continuation.resume()
        }
    }
}
