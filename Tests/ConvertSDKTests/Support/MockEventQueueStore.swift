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
actor MockEventQueueStore: EventQueueStore {
    /// The events currently "on disk": set by ``persist(_:)`` / ``seed(_:)``, emptied by ``clear()``,
    /// returned by ``load()``. A test reads it to confirm a side effect landed (or didn't).
    private(set) var storedEvents: [TrackingEvent] = []
    /// Number of times ``load()`` was invoked.
    private(set) var loadCallCount = 0
    /// Number of times ``persist(_:)`` was invoked.
    private(set) var persistCallCount = 0
    /// Number of times ``clear()`` was invoked — the 2xx-upload-clears-the-queue signal under test.
    private(set) var clearCallCount = 0

    func load() async throws -> [TrackingEvent] {
        loadCallCount += 1
        return storedEvents
    }

    func persist(_ events: [TrackingEvent]) async throws {
        persistCallCount += 1
        storedEvents = events
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
}
