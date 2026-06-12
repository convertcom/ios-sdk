// Tests/ConvertSDKTests/Integration/ConcurrencyTests.swift
//
// FR70 concurrency integration suite (Epic 5 / Story 5 — full-chain payload structure +
// concurrency staging). Proves the EventQueue's exactly-once delivery contract under a
// foreground-flush ↔ background-drain race, and the re-persist-on-failure durable fallback (AC4).
// Drives the REAL `EventQueue` over a temp-file `CoordinatedFileEventQueueStore` through the shared
// T0 factory `makeQueueWithTempFileAndUploader()` (TestFixtures.swift); never constructs the queue
// inline (SonarQube 3% new-duplicated-lines gate — the single construction path lives in that
// factory).
//
// ── RED-phase state ─────────────────────────────────────────────────────────────────────────────
// `exactlyOnceUnderConcurrentDrain` (item 1) compiles TODAY: it uses only existing APIs
// (`enqueue`/`drain`, `withTaskGroup`, JSON identity read-back). `rePersistsBatchOnUploadFailure`
// (item 2) is the RED-making reference: it calls `await sut.uploader.setShouldFail(true)`, a
// failure-injection mutator that does NOT yet exist on `MockEventUploader` (the mock currently ALWAYS
// succeeds — verified in MockBackgroundDelivery.swift). GREEN adds that one `async` mutator plus the
// error it throws (see the comment on the failure test). This file touches NO Sources/.
//
// ── Identity-derivation choice: ENCODED experienceId (not a bare count) ──────────────────────────
// The exactly-once contract has TWO halves — no event DUPLICATED, no event LOST. A bare count
// (union == N) proves only cardinality: a bug delivering "exp-3" twice while dropping "exp-7" still
// totals N. Reading each delivered entry's DISTINCT `experienceId` and asserting the multiset has no
// repeat AND the set equals `{"exp-0"…"exp-(N-1)"}` proves BOTH halves precisely. The entry payload is
// `private` (TrackingEventEntry), so `experienceId` is recovered by encoding the drained envelope to
// JSON and reading `data.experienceId` — the established read-back pattern in
// `TrackingEventCodableTests` (`events.data["experienceId"]`). A count cross-check (the flattened
// union length) rides alongside so a duplicate is caught even before the Set collapses it.
//
// ── No wall-clock waits (NFR21/NFR22) ────────────────────────────────────────────────────────────
// All concurrency is sequenced via `withTaskGroup` — no `Thread.sleep`, no `Task.sleep`, no poll. The
// race is two concurrent `drain()` callers; actor isolation serializes them, so the union of their
// results is deterministic regardless of which wins.
import Testing
import Foundation
@testable import ConvertSDK

@Suite("ExactlyOnceDelivery")
struct ExactlyOnceDeliveryTests {

    // MARK: - Identity read-back (encoded experienceId)

    /// The set of `experienceId`s carried by a drained batch, recovered by encoding each envelope to
    /// JSON and reading every entry's flat `data.experienceId`. Returns an ARRAY (the multiset), not a
    /// Set, so the caller can assert BOTH "no duplicate" (array has no repeat) and "none lost" (the set
    /// of the array covers all N) — collapsing to a Set here would hide a duplicate. Records an `Issue`
    /// and returns `[]` on any decode-shape miss rather than force-unwrapping (no `!` — swiftlint
    /// `--strict`). Mirrors the `[[String: Any]]` JSON-tree walk in `TrackingEventCodableTests`, the
    /// only way to read a bucketing entry's `experienceId` back (the entry's payload is `private`).
    private static func experienceIds(in batches: [TrackingEvent]) -> [String] {
        var ids: [String] = []
        for envelope in batches {
            guard let data = try? JSONEncoder().encode(envelope),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let visitors = root["visitors"] as? [[String: Any]] else {
                Issue.record("drained envelope did not encode to the expected visitors[] JSON shape")
                return []
            }
            for visitor in visitors {
                let events = visitor["events"] as? [[String: Any]] ?? []
                for event in events {
                    if let payload = event["data"] as? [String: Any],
                       let experienceId = payload["experienceId"] as? String {
                        ids.append(experienceId)
                    }
                }
            }
        }
        return ids
    }

    // MARK: - 1. Exactly-once under a concurrent drain race (FR70)

    /// The event counts the race is proven at. A parameterized argument (NOT two copy-paste N=5 / N=20
    /// functions — SonarQube 3% CPD gate); a typed `[Int]` keeps the `@Test` argument inference simple,
    /// mirroring the typed-cases convention in `TrackingEventCodableTests`.
    static let raceEventCounts = [5, 20]

    /// FR70 — two concurrent `drain()` callers racing the SAME populated queue deliver every enqueued
    /// event EXACTLY once: their union has no duplicate and loses nothing.
    ///
    /// Enqueues N bucketing entries with DISTINCT experienceIds (`"exp-0"…"exp-(N-1)"`) for ONE visitor,
    /// then fires two `drain()` callers concurrently via `withTaskGroup`. `drain()` reads+clears both
    /// the disk and the in-memory buffer in ONE actor step (verified in EventQueue.drain), so actor
    /// isolation makes one caller win the whole batch and the other observe `[]` — the union is exactly
    /// the N enqueued ids with no repeat. That atomicity IS the exactly-once property under concurrency.
    /// Uses only existing APIs, so this test COMPILES in RED (only item 2 is RED).
    @Test("concurrent drain callers deliver every event exactly once", arguments: raceEventCounts)
    func exactlyOnceUnderConcurrentDrain(eventCount: Int) async {
        let sut = await makeQueueWithTempFileAndUploader()
        defer { try? FileManager.default.removeItem(at: sut.url) }

        // Enqueue N entries with DISTINCT experienceIds, same visitor — the identity per event is its
        // experienceId, so a duplicate or a loss is detectable in the drained union.
        for index in 0..<eventCount {
            await sut.queue.enqueue(
                .bucketing(BucketingEventData(experienceId: "exp-\(index)", variationId: "var-\(index)")),
                for: "visitor-race",
                segments: nil
            )
        }

        // Race two concurrent drains. Actor isolation serializes them; one wins the full batch, the
        // other gets []. No wall-clock sequencing — the task group is the only ordering primitive.
        var results: [[TrackingEvent]] = []
        await withTaskGroup(of: [TrackingEvent].self) { group in
            group.addTask { await sut.queue.drain() }
            group.addTask { await sut.queue.drain() }
            for await result in group {
                results.append(result)
            }
        }

        // The FR70 invariant: across the union of BOTH drain results, every enqueued event appears
        // EXACTLY once. The multiset of delivered experienceIds must (a) have length == N — none lost,
        // none extra — and (b) collapse to the full distinct set — no id delivered twice.
        let deliveredIds = Self.experienceIds(in: results.flatMap { $0 })
        let expectedIds = Set((0..<eventCount).map { "exp-\($0)" })
        #expect(deliveredIds.count == eventCount, "union must total N events — none lost, none duplicated")
        #expect(Set(deliveredIds) == expectedIds, "union must be the full distinct id set — no duplicate, no loss")
        #expect(Set(deliveredIds).count == deliveredIds.count, "no experienceId delivered more than once")

        // A SECOND drain after the race returns nothing — disk + buffer were cleared atomically, so no
        // entry is ever drained a third time (the exactly-once tail).
        let afterRace = await sut.queue.drain()
        #expect(afterRace.isEmpty, "both surfaces cleared atomically — a later drain yields nothing")
    }

    // MARK: - 2. Re-persist-on-failure via the real flush() path (AC4)

    /// AC4 — when the uploader THROWS, `flush()` re-persists the drained batch to the store so the
    /// events are NOT lost: a subsequent `drain()` returns them disk-first.
    ///
    /// Exercises the REAL `flush()` failure branch (EventQueue.flush → `catch` → `store.persist`), NOT
    /// a manual re-enqueue shortcut. Flow: enqueue one known entry, flip the uploader to FAIL, call
    /// `flush()` (the failing upload throws ⇒ flush re-persists the merged batch to disk), then `drain()`
    /// and assert the entry comes back — proving the durable fallback recovered it.
    ///
    /// ── RED-making reference (GREEN adds this) ───────────────────────────────────────────────────
    /// `MockEventUploader` currently ALWAYS succeeds — it has no failure injection (verified in
    /// MockBackgroundDelivery.swift). This test references `await sut.uploader.setShouldFail(true)`: an
    /// `async` mutator on the `MockEventUploader` actor that makes its next `upload(_:)` THROW. GREEN
    /// adds (1) that `func setShouldFail(_:) async` mutator and (2) the error `upload` throws when the
    /// flag is set (any `Error` triggers flush's `catch` — its concrete type is not asserted here).
    /// A settable toggle (NOT a new `makeQueueWithFailingUploader()` factory variant, NOT an
    /// `init(failUploads:)` flag) is chosen on purpose: it REUSES the single existing T0 factory rather
    /// than duplicating its queue↔store↔uploader wiring (SonarQube 3% new-code-duplication gate), and it
    /// matches the actor's existing `async` mutator idiom. Until GREEN adds `setShouldFail`, this file
    /// fails to compile with "value of type 'MockEventUploader' has no member 'setShouldFail'" — the
    /// expected RED for this test.
    @Test("flush re-persists the batch to disk when the upload fails, so a later drain recovers it")
    func rePersistsBatchOnUploadFailure() async {
        let sut = await makeQueueWithTempFileAndUploader()
        defer { try? FileManager.default.removeItem(at: sut.url) }

        // Flip the uploader to fail BEFORE flushing, so the real flush() upload throws and takes the
        // re-persist branch. (GREEN adds `setShouldFail(_:)` to MockEventUploader — see the doc above.)
        await sut.uploader.setShouldFail(true)

        // One known entry whose identity (experienceId) we re-read after recovery.
        await sut.queue.enqueue(
            .bucketing(BucketingEventData(experienceId: "exp-persist", variationId: "var-persist")),
            for: "visitor-persist",
            segments: nil
        )

        // The REAL failure path: flush() drains, the failing uploader throws, flush re-persists the
        // merged batch to disk (it does NOT re-buffer — disk becomes the single source of truth).
        await sut.queue.flush()

        // The events survived: a drain re-reads them disk-first. The re-persisted batch comes back with
        // its experienceId intact — exactly one entry, not lost, not duplicated.
        let redrained = await sut.queue.drain()
        let recoveredIds = Self.experienceIds(in: redrained)
        #expect(recoveredIds == ["exp-persist"], "the failed batch must be re-persisted and recovered, not lost")
    }
}
