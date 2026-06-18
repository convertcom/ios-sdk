// Tests/ConvertSDKTests/Integration/ConcurrencyTests.swift
//
// FR70 concurrency integration suite (Epic 5 / Story 5 — full-chain payload structure +
// concurrency staging). Proves the EventQueue's exactly-once delivery contract under a concurrent
// `drain()` race, and the re-persist-on-failure durable fallback (AC4). Drives the REAL `EventQueue`
// over a temp-file `CoordinatedFileEventQueueStore` through the shared T0 factory
// `makeQueueWithTempFileAndUploader()` (TestFixtures.swift); never constructs the queue inline
// (SonarQube 3% new-duplicated-lines gate — the single construction path lives in that factory).
//
// ── Exactly-once is asserted CROSS-SURFACE ───────────────────────────────────────────────────────
// FR70 is "every event delivered exactly once across EVERY consumer". A populated `EventQueue` can
// hand an event to two surfaces: the `uploader` (the size-flush path — `uploadedBatches()`) and a
// manual `drain()` result. `exactlyOnceUnderConcurrentDrain` unions the experienceIds from BOTH the
// uploader's batches AND every drain (the two racing drains + the post-race tail) and asserts each id
// appears EXACTLY once across that whole union — so an event delivered to one surface but missed by
// another is caught, never producing a false-empty union. The drain race uses below-`batchSize` event
// counts so no detached size-flush Task ever fires (see `raceEventCounts` for the determinism
// rationale): the two `drain()` callers are then the only populated surface and the race is
// deterministic. This file touches NO Sources/.
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

    /// The event counts the drain race is proven at — BOTH strictly below ``Defaults/batchSize`` (10).
    /// A parameterized argument (NOT two copy-paste functions — SonarQube 3% CPD gate); a typed `[Int]`
    /// keeps the `@Test` argument inference simple, mirroring the typed-cases convention in
    /// `TrackingEventCodableTests`.
    ///
    /// ── Why below `batchSize`, not `[5, 20]` (the DETERMINISM constraint) ─────────────────────────
    /// `EventQueue.enqueue` launches a DETACHED size flush — `Task { await self.flush() }` — on EVERY
    /// enqueue once `buffer.count >= batchSize` (verified in EventQueue.swift `enqueue`). For an N ≥ 10
    /// (e.g. 20) that is up to N − 9 detached flush Tasks (enqueue #10…#N each re-fire, since launching
    /// the Task does NOT synchronously clear the buffer), and the queue retains NO handle to any of them
    /// (unlike `timerTask`). Each runs `drain()` into a task-local batch then parks at `uploader.upload`.
    /// There is therefore NO happens-before for "all size-flush Tasks have settled": an extra `flush()`
    /// only quiesces the queue's surfaces — it cannot await a detached Task already parked at `upload`
    /// with events drained into its locals — and `waitForBatchCount(K)` needs a FIXED K, but the number
    /// of non-empty delivered batches is timing-dependent (one batch of N, or several splits, plus empty
    /// no-op flushes). Reading `uploadedBatches()` while those Tasks may be in flight is inherently racy,
    /// and the queue is production (no Sources/ change) so no join point can be added. Keeping BOTH N
    /// below `batchSize` means ZERO size-flush Tasks ever launch, so the two manual `drain()` callers are
    /// the only delivery surface and the race is DETERMINISTIC. 9 is the max below-threshold value, so the
    /// larger case still exercises a full-but-not-flushing buffer right at the size-trigger boundary.
    /// (The > `batchSize` auto-flush exactly-once path is covered DETERMINISTICALLY by the core suite's
    /// `EventQueueTests` Scenario 5 + Scenario 12, where a KNOWN upload count makes the uploader-side
    /// union awaitable via `awaitUploadCount`; it cannot be made deterministic from this drain-race seam.)
    static let raceEventCounts = [5, 9]

    /// FR70 — every enqueued event is delivered EXACTLY once across the union of ALL delivery surfaces
    /// while two `drain()` callers race the SAME populated queue: no duplicate, nothing lost.
    ///
    /// Enqueues N bucketing entries with DISTINCT experienceIds (`"exp-0"…"exp-(N-1)"`) for ONE visitor,
    /// then fires two `drain()` callers concurrently via `withTaskGroup`. `drain()` reads+clears both
    /// the disk and the in-memory buffer in ONE actor step (verified in EventQueue.drain), so actor
    /// isolation makes one caller win the whole batch and the other observe `[]`.
    ///
    /// ── Exactly-once is asserted CROSS-SURFACE (FR70's true contract) ─────────────────────────────
    /// FR70 is "exactly once across EVERY consumer", not just across the two drains. The two delivery
    /// surfaces a populated `EventQueue` can hand an event to are (1) the `uploader` (the size-flush
    /// path — `uploadedBatches()`) and (2) a manual `drain()` result. So the assertion unions the
    /// experienceIds from ALL of them — `sut.uploader.uploadedBatches()` (flattened), both racing drain
    /// results, AND the post-race drain — and requires each id to appear EXACTLY once across that whole
    /// union. With N < `batchSize` (see ``raceEventCounts``) no size flush ever fires, so the uploader
    /// surface is empty here and the two drains carry everything; including the uploader in the union
    /// anyway makes the check cross-surface-COMPLETE by construction — an event that ever leaked to the
    /// uploader (e.g. if the size trigger fired) would be COUNTED, never silently dropped, so the
    /// "delivered to the uploader, missed by the drains" failure mode that an N ≥ `batchSize` parameter
    /// would hit is caught rather than producing a false empty union.
    @Test("concurrent drain callers deliver every event exactly once across all surfaces", arguments: raceEventCounts)
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

        // A drain after the race returns nothing — disk + buffer were cleared atomically by whichever
        // racing drain won, so no entry is ever drained again (the exactly-once tail). Captured here as a
        // THIRD delivery surface (empty in the steady case) so the union below is complete.
        let afterRace = await sut.queue.drain()
        #expect(afterRace.isEmpty, "both surfaces cleared atomically — a later drain yields nothing")

        // The FR70 invariant is exactly-once across EVERY delivery surface. Gather the delivered
        // experienceIds from ALL of them via the single `experienceIds(in:)` helper (one JSON walk, no
        // duplicated read-back — SonarQube 3% CPD gate) and concatenate the multisets:
        //   1. the uploader's batches (the size-flush path) — empty here since N < batchSize, but unioned
        //      so any event that ever reached the uploader is counted, never silently lost;
        //   2. both racing drain results;
        //   3. the post-race drain (the exactly-once tail).
        let uploaderBatches = await sut.uploader.uploadedBatches()
        let deliveredIds =
            Self.experienceIds(in: uploaderBatches.flatMap { $0 })
            + Self.experienceIds(in: results.flatMap { $0 })
            + Self.experienceIds(in: afterRace)
        let expectedIds = Set((0..<eventCount).map { "exp-\($0)" })
        // (a) the multiset totals N — none lost, none extra; (b) it collapses to the full distinct set —
        // every id present; (c) the set count equals the array count — no id delivered on TWO surfaces
        // (the key cross-surface exactly-once check: an event must not appear in BOTH an uploader batch
        // and a drain, nor be drained twice).
        #expect(deliveredIds.count == eventCount, "union across all surfaces must total N — none lost, none duplicated")
        #expect(Set(deliveredIds) == expectedIds, "union must be the full distinct id set — no duplicate, no loss")
        #expect(Set(deliveredIds).count == deliveredIds.count, "no experienceId delivered on more than one surface")
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
