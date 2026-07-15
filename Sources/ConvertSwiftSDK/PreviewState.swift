// PreviewState.swift
// Experience-preview in-memory state (qs-02 IOS-4).
//
// Placement rationale: in the `ConvertSwiftSDK` platform target (NOT `ConvertSwiftSDKCore`)
// because it holds a concrete `ConfigFetchService`, which composes the Foundation-backed
// `CoordinatedFileStore` (a platform-layer type) — mirrors `TrackingState`'s placement
// rationale of keeping platform-composed dependencies out of the pure-logic Core target.
//
// `PreviewState` is deliberately NOT single-purpose to the memo: a later story (qs-02 IOS-5)
// will ALSO use this SAME actor to hold the per-context current `(experienceId, variationId)`
// preview target (mirroring `TrackingState`'s "one actor, held by `let`, on the owning type"
// shape), rather than introducing a second actor.

import ConvertSwiftSDKCore
import Foundation

/// Actor-isolated experience-preview state: memoizes
/// `ConfigFetchService.fetchExperienceConfig(experienceId:)` results IN-MEMORY ONLY (never the
/// on-disk config cache), keyed per `experienceId`, with a 60s TTL driven by an injectable
/// ``Clock`` (the same `Clock` port `ConfigRefreshScheduler` already uses).
///
/// Expired entries are swept on EVERY access — both a memo hit/miss check on `resolveConfig`
/// and the read-only ``memoCount`` introspection recompute live-only on demand — bounding
/// growth without a separate timer.
actor PreviewState {
    /// One memoized experience-preview config: the decoded config and the instant it was
    /// fetched. A named struct (not a tuple) keeps the entry self-documenting and gives a
    /// later story (qs-02 IOS-5, the current preview-target field) room to grow this actor's
    /// stored state without reshaping this type.
    private struct MemoEntry {
        let config: ProjectConfig
        let fetchedAt: Date
    }

    /// The memoization TTL: an entry is expired once MORE than this many seconds have
    /// elapsed since it was fetched (exactly `ttl` elapsed is still considered live).
    private static let ttl: TimeInterval = 60

    /// The fetch service used to resolve an experience's preview config on a memo miss.
    private let fetchService: ConfigFetchService
    /// Injectable time source (NFR21) — tests substitute a `MockClock` to advance time
    /// synthetically without a wall-clock wait.
    private let clock: any Clock
    /// The memo surface: one entry per `experienceId`, pruned of expired entries on access.
    private var memo: [String: MemoEntry] = [:]

    /// The current preview target's resolved forced decision (qs-02 IOS-5), or `nil` when no
    /// preview target has been set on the owning context, or the last ``ConvertContext/setPreview``
    /// resolution failed (inert-on-bad-input — the prior value, if any, is simply left in place
    /// since `ConvertContext.setPreview` never calls ``setForcedVariation(_:)`` on a failed resolve).
    /// `ConvertContext.runExperience(_:enableTracking:)` / `runExperiences(enableTracking:)` compare
    /// this `Variation`'s `experienceKey` against the key being run to decide whether to
    /// short-circuit before ``ExperienceManager``.
    private(set) var forcedVariation: Variation?

    /// Creates the preview state.
    /// - Parameters:
    ///   - fetchService: The concrete `ConfigFetchService` used to resolve a memo miss.
    ///   - clock: Time source for TTL math; defaults to ``SystemClock()`` in production.
    init(fetchService: ConfigFetchService, clock: any Clock = SystemClock()) {
        self.fetchService = fetchService
        self.clock = clock
    }

    /// The number of currently LIVE (non-expired) memo entries — test-only introspection.
    /// Recomputed against the CURRENT clock reading on every access, so it reflects reality
    /// even if nothing has triggered a sweep since an entry expired.
    var memoCount: Int {
        liveEntries(at: clock.now).count
    }

    /// Whether a preview target is CURRENTLY set on the owning context (qs-02 IOS-6, AC6 zero-trace
    /// gate): `true` once ``setForcedVariation(_:)`` has recorded a resolved target, `false` when no
    /// ``ConvertContext/setPreview(experienceId:variationId:)`` call has yet succeeded. Mirrors
    /// ``forcedVariation``'s own nil-ness rather than tracking a separate flag, so the two can never
    /// drift out of sync. `ConvertContext` reads this to gate the bucketing enqueue, the sticky-decision
    /// write, and conversion tracking to the SOURCE — independent of the SDK-shared
    /// `ConvertSwiftSDK.isTrackingEnabled()` runtime flag, which is a different (global) axis.
    var isPreviewActive: Bool {
        forcedVariation != nil
    }

    /// Resolves the preview config for `experienceId`, memoizing it in-memory for 60s.
    ///
    /// Sweeps expired entries (across ALL ids, not just `experienceId`) before consulting
    /// the memo, so an access for one id also bounds growth from a different, now-expired
    /// id (qs-02 IOS-4). On a memo hit within the TTL, returns the memoized config with no
    /// fetch. On a miss (absent or expired), fetches via
    /// `ConfigFetchService.fetchExperienceConfig(experienceId:)`; a successful fetch is
    /// memoized, a `nil` fetch is NOT memoized (so the next call retries rather than
    /// caching a failure).
    /// - Parameter experienceId: The experience whose preview config is being resolved.
    /// - Returns: The (possibly memoized) config, or `nil` if the underlying fetch failed.
    func resolveConfig(experienceId: String) async -> ProjectConfig? {
        let now = clock.now
        memo = liveEntries(at: now)

        if let entry = memo[experienceId] {
            return entry.config
        }

        guard let config = await fetchService.fetchExperienceConfig(experienceId: experienceId) else {
            return nil
        }
        memo[experienceId] = MemoEntry(config: config, fetchedAt: clock.now)
        return config
    }

    /// Records the resolved forced-decision target for the owning context (qs-02 IOS-5).
    /// `ConvertContext.setPreview(experienceId:variationId:)` calls this ONLY after successfully
    /// resolving `experienceId`/`variationId` into a ``Variation`` via
    /// ``PreviewDecision/forcedVariation(for:variationId:)`` — an unresolved `setPreview` call
    /// never reaches here, leaving any prior target untouched.
    /// - Parameter variation: The forced decision to record.
    func setForcedVariation(_ variation: Variation) {
        forcedVariation = variation
    }

    /// Filters ``memo`` down to entries that are not yet expired as of `now`.
    /// - Parameter now: The clock reading to measure elapsed time against.
    /// - Returns: The subset of ``memo`` whose age is at most ``ttl``.
    private func liveEntries(at now: Date) -> [String: MemoEntry] {
        memo.filter { now.timeIntervalSince($0.value.fetchedAt) <= Self.ttl }
    }
}
