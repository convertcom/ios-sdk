// DecisionStore.swift
// Visitor-keyed sticky-variation store (Epic 3 / Story 4). Holds the per-visitor
// `[String: StoreData]` map in actor-isolated memory with an LRU cap, hydrates from /
// persists to disk through the injected `FileStore`, and degrades to an empty store on
// corrupt bytes. Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Visitor-keyed decision store: sticky variations with an LRU-bounded in-memory cache that
/// persists through the injected ``FileStore``.
///
/// An `actor` (not a `final class`) so every read/write of the decision map is serialized with
/// NO locks and NO `Sendable` suppression (AR12). The store key is the full
/// `accountId-projectId-visitorId` string; the caller builds it.
///
/// LRU semantics: ``accessOrder`` lists keys oldest-first. A sticky HIT (a read) and every
/// ``saveDecision(variationId:experienceId:storeKey:)`` bump the key to the
/// most-recently-used end, so a read — not just a write — refreshes recency. When the cache is
/// at ``maxEntries`` and a NEW key is inserted, the least-recently-accessed key is evicted first.
public actor DecisionStore {
    /// Log sink for the corruption-recovery warning.
    private let logger: Logger
    /// Atomic file-I/O port the decision map persists through.
    private let fileStore: FileStore
    /// The in-memory decision map, keyed by `accountId-projectId-visitorId`.
    private var store: [String: StoreData] = [:]
    /// LRU recency, oldest key first; the last element is most-recently-used.
    private var accessOrder: [String] = []
    /// LRU capacity — the maximum number of visitor keys held in memory.
    private let maxEntries: Int
    /// On-disk location of the persisted decision map (Application Support, with a fixed name).
    private let fileURL: URL

    /// Fixed filename for the persisted decision map under Application Support.
    private static let storeFileName = "convert-decision-store.json"

    /// The on-disk shape: the decision map PLUS the LRU access order, so eviction recency
    /// survives app restarts (the in-memory `accessOrder` would otherwise be reseeded from
    /// `Dictionary.keys`, whose order is non-deterministic across launches).
    private struct PersistedStore: Codable {
        let store: [String: StoreData]
        let order: [String]
    }

    /// Injects the log sink, the file-I/O port, and the LRU capacity.
    ///
    /// The persistence URL is resolved once here: Application Support if available, falling back
    /// to the caches directory and finally to the temporary directory. Init never throws and
    /// never crashes — an unresolved directory degrades to a still-usable temporary path.
    ///
    /// - Parameters:
    ///   - logger: Sink for the corruption-recovery warning emitted by ``loadFromDisk()``.
    ///   - fileStore: Atomic file-I/O port the decision map is read from and written to.
    ///   - maxEntries: LRU capacity; defaults to ``Defaults/localStoreLimit``.
    public init(logger: Logger, fileStore: FileStore, maxEntries: Int = Defaults.localStoreLimit) {
        self.logger = logger
        self.fileStore = fileStore
        self.maxEntries = maxEntries
        self.fileURL = Self.resolveStoreURL()
    }

    /// Hydrates the in-memory store from disk. Reads via ``fileStore``, decodes a
    /// ``PersistedStore`` (the decision map plus the persisted LRU access order), and seeds
    /// ``store`` / ``accessOrder``. Because the access order is persisted, eviction recency
    /// survives app restarts rather than being reseeded from non-deterministic `Dictionary.keys`.
    ///
    /// On ANY failure — a missing file on first launch (`CocoaError`), corrupt / truncated bytes,
    /// or an old / hand-edited file that no longer decodes as ``PersistedStore`` — it logs a
    /// `warn`-level line and leaves the store EMPTY. It never throws and never crashes.
    public func loadFromDisk() async {
        do {
            let data = try await fileStore.read(from: fileURL)
            let decoded = try JSONDecoder().decode(PersistedStore.self, from: data)
            store = decoded.store
            // Rebuild a consistent accessOrder: keep persisted order entries that still exist in
            // store (preserving recency), then append any store keys missing from order (defensive
            // — e.g. a legacy file or a hand-edited one), and drop any order keys absent from store.
            var rebuilt = decoded.order.filter { store[$0] != nil }
            let known = Set(rebuilt)
            for key in store.keys where !known.contains(key) { rebuilt.append(key) }
            accessOrder = rebuilt
        } catch {
            logger.log(
                level: .warn,
                type: "DecisionStore",
                method: "loadFromDisk",
                message: "Decision store missing or corrupt; starting empty (\(error))"
            )
            store = [:]
            accessOrder = []
        }
    }

    /// Returns the sticky variation ID for `experienceId` under `storeKey`, or `nil` if none.
    ///
    /// On a HIT it bumps `storeKey` to the most-recently-used end of the LRU order — so a read
    /// refreshes recency. On a MISS the LRU order is left untouched. Non-suspending (no `await`):
    /// the lookup-and-recency-bump is one atomic actor step (AR12).
    public func stickyVariationId(forExperience experienceId: String, storeKey: String) -> String? {
        guard let variationId = store[storeKey]?.bucketing[experienceId] else {
            return nil
        }
        touch(storeKey)
        return variationId
    }

    /// Returns the whole sticky-bucketing map (`experienceId` → `variationId`) for `storeKey`, or an
    /// empty map when the store holds no entry for that key. The conversion-tracking path reads it to
    /// populate `ConversionEventData.bucketingData`.
    ///
    /// A PURE READ: unlike ``stickyVariationId(forExperience:storeKey:)`` it does NOT ``touch(_:)`` —
    /// it must not bump LRU recency (reporting the visitor's decisions is not an access that should
    /// keep the entry warm). Non-suspending (no `await`): the lookup is one atomic actor step (AR12).
    public func bucketingDecisions(forStoreKey storeKey: String) -> [String: String] {
        store[storeKey]?.bucketing ?? [:]
    }

    /// Merges `variationId` into `storeKey`'s `StoreData.bucketing[experienceId]`, refreshes LRU
    /// recency, and persists the whole decision map — together with the LRU access order — to disk.
    ///
    /// When the cache is at ``maxEntries`` and `storeKey` is NEW, the least-recently-accessed key
    /// is evicted BEFORE the insert. The eviction + merge + recency bump run as one non-suspending
    /// actor step; only the disk write is awaited afterwards (AR12). The persisted ``PersistedStore``
    /// carries ``accessOrder`` so eviction recency survives restarts. Persistence is best-effort —
    /// an encode or write failure is swallowed, never crashing the caller.
    public func saveDecision(variationId: String, experienceId: String, storeKey: String) async {
        if store[storeKey] == nil, store.count >= maxEntries, let oldest = accessOrder.first {
            store[oldest] = nil
            accessOrder.removeFirst()
        }

        let existing = store[storeKey]
        let mergedBucketing = (existing?.bucketing ?? [:])
            .merging([experienceId: variationId]) { _, new in new }
        store[storeKey] = StoreData(
            bucketing: mergedBucketing,
            goalTriggered: existing?.goalTriggered ?? [:],
            segments: existing?.segments ?? Segments(),
            locations: existing?.locations ?? [:]
        )
        touch(storeKey)

        guard let data = try? JSONEncoder().encode(PersistedStore(store: store, order: accessOrder)) else {
            return
        }
        try? await fileStore.write(data, to: fileURL)
    }

    /// Atomically checks whether `goalId` has already been triggered for `forVisitorKey` and, if not,
    /// marks it triggered and persists. Returns `true` when the goal was NOT yet triggered (caller
    /// should proceed with the conversion enqueue), `false` when it was already triggered (caller
    /// should suppress). The contains-check AND the insert are one NON-SUSPENDING step — there is no
    /// `await` between the boolean read and the `goalTriggered` write — so two concurrent calls on the
    /// same goal cannot both observe "not triggered" (actor-reentrancy caveat, AR12). The only suspend
    /// point is the trailing best-effort disk write, which runs AFTER the in-memory mark is committed.
    /// [Source: data-manager.ts:1058-1072,851]
    public func markGoalTriggeredIfNeeded(goalId: String, forVisitorKey storeKey: String) async -> Bool {
        if store[storeKey]?.goalTriggered[goalId] == true {
            return false
        }

        if store[storeKey] == nil, store.count >= maxEntries, let oldest = accessOrder.first {
            store[oldest] = nil
            accessOrder.removeFirst()
        }

        let existing = store[storeKey]
        var mergedGoals = existing?.goalTriggered ?? [:]
        mergedGoals[goalId] = true
        store[storeKey] = StoreData(
            bucketing: existing?.bucketing ?? [:],
            goalTriggered: mergedGoals,
            segments: existing?.segments ?? Segments(),
            locations: existing?.locations ?? [:]
        )
        touch(storeKey)

        guard let data = try? JSONEncoder().encode(PersistedStore(store: store, order: accessOrder)) else {
            return true
        }
        try? await fileStore.write(data, to: fileURL)
        return true
    }

    /// Returns the current ``Segments`` for `key`, or `Segments()` when the store holds no entry.
    ///
    /// A PURE READ — like ``bucketingDecisions(forStoreKey:)`` it does NOT ``touch(_:)`` (reporting a
    /// visitor's segments is not an access that should bump LRU recency) and is NON-suspending (one
    /// atomic actor step, AR12). [Source: AC10]
    public func currentSegments(forVisitorKey key: String) -> Segments {
        store[key]?.segments ?? Segments()
    }

    /// Writes `segments` into `key`'s ``StoreData/segments``, preserving the other three fields, and
    /// persists the whole decision map (plus LRU order) to disk.
    ///
    /// The segment write is a SINGLE UNCONDITIONAL mutation (no read→conditional→write), so unlike
    /// ``markGoalTriggeredIfNeeded(goalId:forVisitorKey:)`` there is no reentrancy hazard. When the cache
    /// is at ``maxEntries`` and `key` is NEW, the least-recently-used key is evicted BEFORE the insert.
    /// The evict + reconstruct + recency bump run as one non-suspending step; only the best-effort disk
    /// write is awaited afterwards (AR12). [Source: AC5, AC10]
    public func setSegments(_ segments: Segments, forVisitorKey key: String) async {
        if store[key] == nil, store.count >= maxEntries, let oldest = accessOrder.first {
            store[oldest] = nil
            accessOrder.removeFirst()
        }

        let existing = store[key]
        store[key] = StoreData(
            bucketing: existing?.bucketing ?? [:],
            goalTriggered: existing?.goalTriggered ?? [:],
            segments: segments,
            locations: existing?.locations ?? [:]
        )
        touch(key)

        guard let data = try? JSONEncoder().encode(PersistedStore(store: store, order: accessOrder)) else {
            return
        }
        try? await fileStore.write(data, to: fileURL)
    }

    /// Merge-overlays the non-nil fields of `overlay` onto `key`'s existing segments. The read of the
    /// current segments, the overlay, and the write are ONE NON-SUSPENDING step — there is no `await`
    /// between the read and the write — so two concurrent segment merges on the same visitor cannot
    /// both observe the same baseline and lose an overlay (the lost-update race fixed in F-172). A nil
    /// field in `overlay` leaves the stored value untouched (callers send only the keys they want to
    /// set), so prior keys are retained. Mirrors ``markGoalTriggeredIfNeeded(goalId:forVisitorKey:)``:
    /// the only suspend point is the trailing best-effort disk write, which runs AFTER the in-memory
    /// segments are committed. When the cache is at ``maxEntries`` and `key` is NEW, the
    /// least-recently-used key is evicted BEFORE the insert. [Source: AC1, AC10, AC15]
    public func mergeSegments(_ overlay: Segments, forVisitorKey key: String) async {
        if store[key] == nil, store.count >= maxEntries, let oldest = accessOrder.first {
            store[oldest] = nil
            accessOrder.removeFirst()
        }

        let existing = store[key]
        var merged = existing?.segments ?? Segments()
        if let country = overlay.country { merged.country = country }
        if let browser = overlay.browser { merged.browser = browser }
        if let devices = overlay.devices { merged.devices = devices }
        if let source = overlay.source { merged.source = source }
        if let campaign = overlay.campaign { merged.campaign = campaign }
        if let visitorType = overlay.visitorType { merged.visitorType = visitorType }
        if let customSegments = overlay.customSegments { merged.customSegments = customSegments }
        store[key] = StoreData(
            bucketing: existing?.bucketing ?? [:],
            goalTriggered: existing?.goalTriggered ?? [:],
            segments: merged,
            locations: existing?.locations ?? [:]
        )
        touch(key)

        guard let data = try? JSONEncoder().encode(PersistedStore(store: store, order: accessOrder)) else {
            return
        }
        try? await fileStore.write(data, to: fileURL)
    }

    /// Appends `segmentIds` to `key`'s existing `customSegments`. The read, the append, and the write
    /// are ONE NON-SUSPENDING step (no `await` between read and write), so two concurrent appends on
    /// the same visitor cannot both read the same baseline and drop an append (the lost-update race
    /// fixed in F-172). Dedup is left to the backend (matching JS); the six string keys are untouched.
    /// When the cache is at ``maxEntries`` and `key` is NEW, the least-recently-used key is evicted
    /// BEFORE the insert; only the trailing best-effort disk write is awaited (AR12). [Source: AC2, AC10, AC15]
    public func appendCustomSegments(_ segmentIds: [String], forVisitorKey key: String) async {
        if store[key] == nil, store.count >= maxEntries, let oldest = accessOrder.first {
            store[oldest] = nil
            accessOrder.removeFirst()
        }

        let existing = store[key]
        var segments = existing?.segments ?? Segments()
        segments.customSegments = (segments.customSegments ?? []) + segmentIds
        store[key] = StoreData(
            bucketing: existing?.bucketing ?? [:],
            goalTriggered: existing?.goalTriggered ?? [:],
            segments: segments,
            locations: existing?.locations ?? [:]
        )
        touch(key)

        guard let data = try? JSONEncoder().encode(PersistedStore(store: store, order: accessOrder)) else {
            return
        }
        try? await fileStore.write(data, to: fileURL)
    }

    /// Moves `storeKey` to the most-recently-used end of the LRU order.
    private func touch(_ storeKey: String) {
        accessOrder.removeAll { $0 == storeKey }
        accessOrder.append(storeKey)
    }

    /// Resolves the persisted-store URL: Application Support, then caches, then the temporary
    /// directory. Never throws — a fully unresolved environment still yields a usable temp path.
    private static func resolveStoreURL() -> URL {
        let manager = FileManager.default
        if let appSupport = try? manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return appSupport.appendingPathComponent(storeFileName)
        }
        if let caches = try? manager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return caches.appendingPathComponent(storeFileName)
        }
        return manager.temporaryDirectory.appendingPathComponent(storeFileName)
    }
}
