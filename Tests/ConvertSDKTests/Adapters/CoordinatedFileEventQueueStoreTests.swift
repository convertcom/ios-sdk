// Tests/ConvertSDKTests/Adapters/CoordinatedFileEventQueueStoreTests.swift
import Testing
import Foundation
import ConvertSDK

// RED phase (Epic 5, Story 5.2): this suite exercises `CoordinatedFileEventQueueStore`,
// the concrete `EventQueueStore` adapter that persists the pending tracking-event queue
// to disk, which DOES NOT EXIST YET — the GREEN step creates it at
// `Sources/ConvertSDK/Adapters/CoordinatedFileEventQueueStore.swift`. Until then this file
// fails to compile with "cannot find 'CoordinatedFileEventQueueStore' in scope", which is
// the expected RED state for this TDD cycle.
//
// ── Contract under test (for the GREEN implementer) ───────────────────────────
// `public final actor CoordinatedFileEventQueueStore: EventQueueStore` with:
//   * `init(fileURL: URL, logger: any Logger)` — captures the queue-file location and the
//     logger; delegates raw file I/O to the existing `CoordinatedFileStore` actor.
//   * `func load() async throws -> [TrackingEvent]` — reads the file and JSON-decodes it
//     (`.useDefaultKeys`). A MISSING file returns `[]`. A CORRUPT file (decode failure)
//     returns `[]`, logs a WARN, and DELETES the file — it NEVER throws (FR51 / NFR13).
//   * `func persist(_ events: [TrackingEvent]) async throws` — JSON-encodes and writes the
//     queue atomically. `persist([])` is equivalent to `clear()` (no `[]` file left behind).
//   * `func clear() async throws` — removes the queue file; total / no-throw on absence.
//   * `static func queueFileURL() -> URL` — a PURE URL builder (no actor isolation, no I/O),
//     mirroring `CoordinatedFileStore.configCacheURL(for:)`:
//     `{applicationSupportDirectory}/com.convertexperiments.sdk/event-queue.json`.
//     ⚠️ GREEN MUST expose EXACTLY this static, with this name and `() -> URL` signature —
//     `staticBuilderProducesNamespacedQueuePath()` asserts against it.
// Because the store is an `actor`, load/persist/clear are `await` (and `try`); `queueFileURL`
// is `static` — NO `await`.
//
// ── Isolation + cleanup shape (NFR21 — no test artifacts leak) ────────────────
// Each I/O test builds a UNIQUE URL under `FileManager.default.temporaryDirectory` (a fresh
// UUID subdirectory + filename) via `uniqueURL()`, so cases never collide and never touch the
// real Application Support dir. Every UUID dir created is recorded and removed in `deinit`
// (swift-testing makes a fresh suite instance per `@Test` and runs `deinit` after it, giving
// symmetric after-each teardown). This file mirrors `CoordinatedFileStoreTests` exactly: a
// `final class` (so it can carry a `deinit`; a `struct` is `Copyable` and cannot) with its
// recorded-dirs set in a `LockedBox` (the lock-cell the synchronous mocks use, in
// `MockPorts.swift`) so the mutable instance state is `Sendable`-safe under Swift 6 strict
// concurrency on this package's macOS 12 / iOS 15 floor and reads soundly from `deinit`.
@Suite("CoordinatedFileEventQueueStore")
final class CoordinatedFileEventQueueStoreTests {
    /// Temp directories created by ``uniqueURL(filename:)``, removed in ``deinit`` so no test
    /// artifact survives the run (NFR21). Held in a ``LockedBox`` (defined in `MockPorts.swift`)
    /// so this mutable instance state is `Sendable`-safe and can be read back during teardown.
    private let createdDirs = LockedBox<[URL]>([])

    /// Removes every temp directory this suite created (NFR21). Runs after each `@Test` (fresh
    /// suite instance per case), so no scratch dir leaks into the next case or another suite.
    deinit {
        let manager = FileManager.default
        for dir in createdDirs.get {
            try? manager.removeItem(at: dir)
        }
    }

    // MARK: - Shared helpers (defined once, used everywhere — SonarQube new-code dup gate)

    /// The system under test paired with the logger it was built with. A named struct (not a
    /// tuple) keeps the `large_tuple` lint rule satisfied and lets cases read fields by name.
    private struct Subject {
        let store: CoordinatedFileEventQueueStore
        let logger: MockLogger
    }

    /// Builds the SUT over `fileURL` with a fresh ``MockLogger`` and returns both. Factored out
    /// so no case repeats the construction (SonarQube new-code-duplication discipline).
    private func makeStore(fileURL: URL) -> Subject {
        let logger = MockLogger()
        let store = CoordinatedFileEventQueueStore(fileURL: fileURL, logger: logger)
        return Subject(store: store, logger: logger)
    }

    /// Builds a UNIQUE file URL under a fresh UUID temp subdirectory and records that
    /// subdirectory for ``deinit`` cleanup. The returned URL's PARENT does not exist on disk yet
    /// (exercising the adapter's "create intermediate dirs" path through `CoordinatedFileStore`)
    /// and is unique per call so cases never collide. Centralizing this here is what keeps the
    /// temp-URL construction from being copy-pasted across tests.
    private func uniqueURL(filename: String = "event-queue.json") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        createdDirs.withLock { $0.append(dir) }
        return dir.appendingPathComponent(filename)
    }

    /// Builds ONE ``TrackingEvent`` via the real initializers (a single bucketing entry under a
    /// single visitor). Parameterized so cases needing different wire-critical fields reuse this
    /// rather than re-instantiating the model — the only duplication-safe way to vary an event.
    private func makeEvent(
        visitorId: String = "visitor-1",
        experienceId: String = "exp-1",
        variationId: String = "var-1"
    ) -> TrackingEvent {
        let entry = TrackingEventEntry.bucketing(
            BucketingEventData(experienceId: experienceId, variationId: variationId)
        )
        let visitor = Visitor(visitorId: visitorId, segments: ["country": "US"], events: [entry])
        return TrackingEvent(accountId: "acc-1", projectId: "proj-1", visitors: [visitor])
    }

    // MARK: - Cases

    /// `persist` then `load` round-trips a single event with its wire-critical fields intact
    /// (the visitor id and the entry's `eventType`). A fresh unique URL keeps the case isolated.
    @Test("persist then load round-trips an event with wire-critical fields preserved")
    func roundTripPreservesWireCriticalFields() async throws {
        let subject = makeStore(fileURL: uniqueURL())
        let event = makeEvent(visitorId: "visitor-rt")

        try await subject.store.persist([event])
        let loaded = try await subject.store.load()

        #expect(loaded.count == 1)
        let visitor = try #require(loaded.first?.visitors.first, "round-tripped event lost its visitor")
        #expect(visitor.visitorId == "visitor-rt")
        #expect(visitor.events.first?.eventType == "bucketing")
    }

    /// After `persist([event])` the queue file exists at exactly the supplied `fileURL`
    /// (deterministic path; the atomic write through `CoordinatedFileStore` lands the bytes).
    @Test("persist writes the file at the supplied fileURL")
    func persistWritesFileAtFileURL() async throws {
        let fileURL = uniqueURL()
        let subject = makeStore(fileURL: fileURL)

        try await subject.store.persist([makeEvent()])

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// `clear` removes the queue file: it exists after `persist`, then is gone after `clear`.
    @Test("clear removes the persisted queue file")
    func clearRemovesFile() async throws {
        let fileURL = uniqueURL()
        let subject = makeStore(fileURL: fileURL)
        try await subject.store.persist([makeEvent()])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        try await subject.store.clear()

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// `load` on a never-written URL returns `[]` (a missing file is an empty queue, not an
    /// error) — the store must NOT throw here.
    @Test("load on a missing file returns an empty array")
    func loadOnMissingFileReturnsEmpty() async throws {
        let subject = makeStore(fileURL: uniqueURL())

        let loaded = try await subject.store.load()

        #expect(loaded.isEmpty)
    }

    /// A file that exists but holds invalid JSON is recovered: `load` returns `[]`, a WARN is
    /// logged, and the file is re-initialized so a subsequent `persist` + `load` works. The WARN
    /// assertion uses ``MockLogger/waitForEntry(level:type:method:messageContains:)`` (a genuine
    /// happens-before on the logged line) BEFORE inspecting `entries` — no polling, no wall-clock.
    @Test("load on a corrupt file returns empty, logs a WARN, and re-initializes the queue")
    func loadOnCorruptFileRecoversAndWarns() async throws {
        let fileURL = uniqueURL()
        let subject = makeStore(fileURL: fileURL)
        // Write bytes that are NOT decodable as `[TrackingEvent]` straight to the queue path.
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not valid json".utf8).write(to: fileURL)

        let loaded = try await subject.store.load()
        #expect(loaded.isEmpty)

        await subject.logger.waitForEntry(level: .warn)
        #expect(!subject.logger.entries().filter { $0.level == .warn }.isEmpty)

        // The corrupt file was discarded, so the queue re-initializes cleanly on the next write.
        try await subject.store.persist([makeEvent(visitorId: "visitor-recovered")])
        let reloaded = try await subject.store.load()
        #expect(reloaded.first?.visitors.first?.visitorId == "visitor-recovered")
    }

    /// `persist([])` is equivalent to `clear()`: no `[]` JSON file is left behind, so a following
    /// `load` returns `[]`.
    @Test("persist of an empty array leaves load returning empty")
    func persistEmptyLeavesEmpty() async throws {
        let subject = makeStore(fileURL: uniqueURL())

        try await subject.store.persist([])
        let loaded = try await subject.store.load()

        #expect(loaded.isEmpty)
    }

    /// `queueFileURL()` builds the queue path under the Application Support directory, namespaced
    /// by the SDK bundle id, with the fixed `event-queue.json` filename. Pure URL construction —
    /// no actor hop (`static`, no `await`) and no file I/O. ⚠️ GREEN must expose EXACTLY this
    /// static (name `queueFileURL`, signature `() -> URL`), mirroring `configCacheURL(for:)`.
    @Test("queueFileURL is under Application Support with the namespaced queue filename")
    func staticBuilderProducesNamespacedQueuePath() throws {
        let url = CoordinatedFileEventQueueStore.queueFileURL()

        #expect(url.path.hasSuffix("com.convertexperiments.sdk/event-queue.json"))

        let appSupport = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            "no Application Support directory on this platform"
        )
        #expect(url.path.hasPrefix(appSupport.path))
    }
}
