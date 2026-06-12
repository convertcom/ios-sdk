// Sources/ConvertSDKCore/Bucketing/BucketingManager.swift
// Deterministic, cross-SDK-parity bucketing (Epic 3 / Story 2).
// Foundation-only — part of the pure-logic ConvertSDKCore target.
//
// PARITY NOTE — this mirrors the Convert JavaScript SDK's decisioning path exactly:
//   * The hash key is `"\(experienceId)\(visitorId)"` — experience id FIRST, visitor id
//     second, with NO separator — fed as UTF-8 bytes to MurmurHash3 (x86, 32-bit) seeded
//     with ``Defaults/hashSeed``.
//   * The 32-bit hash is projected onto `0..<maxTraffic` (0..<10000) via
//     `Int(Double(hash) / Double(maxHash) * Double(maxTraffic))`.
//   * ``selectBucket(weights:value:)`` walks variations in order, accumulating their
//     weights, and returns the FIRST whose running total strictly exceeds `value`
//     (`value < prev`) — accumulate-first-wins. An uncovered tail returns `nil`.
//
// SCALE NOTE — `traffic_allocation` on the generated `ExperienceVariationConfig` is already
// "a number from 0 to 10000" (per its schema doc), i.e. already in bucket-units. It is used
// DIRECTLY as the weight — there is NO `*100` on the production path. (The parity test drives
// ``selectBucket`` with pre-scaled bucket-units too, so the helper itself never scales.)
//
// STATELESS (AC13): a plain `struct` with two `let` port dependencies — no actor, no mutable
// state. `bucket(...)` is `async` only because ``EventSink/enqueue(_:)`` is `async`; it never
// throws — any unbucketable input degrades to `nil` (and a warning) rather than propagating.

import Foundation

/// Resolves the variation a visitor is bucketed into for an experience, deterministically and
/// in agreement with the other Convert SDKs.
internal struct BucketingManager {
    private let eventSink: EventSink
    private let logger: Logger

    init(eventSink: EventSink, logger: Logger) {
        self.eventSink = eventSink
        self.logger = logger
    }

    /// A variation that is eligible for bucketing: its `key` (the variation id used as the
    /// selection key) paired with the full config it resolves back to and its bucket-unit
    /// `weight`. A named struct rather than a 3-member tuple so the `large_tuple` lint rule
    /// (max 2 members) stays satisfied.
    private struct WeightedVariation {
        let key: String
        let weight: Int
        let config: Components.Schemas.ExperienceVariationConfig
    }

    /// Buckets `visitorId` into one of `experience`'s variations.
    ///
    /// Returns `nil` when the experience is unidentifiable, has no eligible variations, or the
    /// visitor's bucket value falls outside the allocated traffic. On a successful bucket with
    /// `enableTracking == true`, enqueues exactly one bucketing event before returning.
    ///
    /// Never throws: every failure mode degrades to `nil` (with a warning where it indicates a
    /// malformed config), so a bad experience can never crash the decisioning path.
    func bucket(
        visitorId: String,
        experience: Components.Schemas.ConfigExperience,
        enableTracking: Bool = true
    ) async -> Variation? {
        // 1. An experience with no id cannot be hashed or attributed — degrade to nil.
        guard let experienceId = experience.id else {
            logger.log(
                level: .warn,
                type: "BucketingManager",
                method: "bucket",
                message: "Experience has no id; cannot bucket visitor."
            )
            return nil
        }

        // 2–3. Hash "<experienceId><visitorId>" (id first, no separator) → 32-bit MurmurHash3.
        let input = Array("\(experienceId)\(visitorId)".utf8)
        let hashValue = MurmurHash3.hash(input, seed: Defaults.hashSeed)

        // 4. Project the hash onto the bucket range 0..<maxTraffic (0..<10000).
        let bucketValue = Int(
            Double(hashValue) / Double(Defaults.maxHash) * Double(Defaults.maxTraffic)
        )

        // 5. Keep only variations that carry BOTH an id and a traffic_allocation — a variation
        //    missing either can't be bucketed into. `traffic_allocation` is already 0..10000
        //    (bucket-units), so it's the weight directly (NO *100). Order is preserved.
        let eligible: [WeightedVariation] = (experience.variations ?? []).compactMap { variation in
            guard let key = variation.id, let allocation = variation.traffic_allocation else {
                return nil
            }
            return WeightedVariation(key: key, weight: Int(allocation), config: variation)
        }
        let weights = eligible.map { (key: $0.key, weight: $0.weight) }

        // 6. Select the variation whose cumulative weight first exceeds the bucket value.
        //    No selection (visitor outside allocated traffic) → return nil, enqueue nothing.
        guard let selectedKey = BucketingManager.selectBucket(weights: weights, value: bucketValue) else {
            return nil
        }

        // 7. Map the selected key back onto its config and build the result variation. (`first`
        //    is non-optional-safe here — `selectedKey` came from `eligible` — but bind it
        //    rather than force-unwrap, degrading to nil if it ever can't be found.)
        guard let selected = eligible.first(where: { $0.key == selectedKey })?.config else {
            return nil
        }
        let variation = Variation(
            id: selected.id ?? "",
            key: selected.key ?? "",
            experienceId: experienceId,
            experienceKey: experience.key ?? ""
        )

        // 8. Emit exactly one bucketing event when tracking is enabled; otherwise stay silent.
        if enableTracking {
            let data = BucketingEventData(experienceId: experienceId, variationId: selected.id ?? "")
            await eventSink.enqueue(.bucketing(data))
        }

        // 9. Return the resolved variation.
        return variation
    }

    /// Accumulate-first-wins bucket selection (AC5), byte-identical to the JS SDK's
    /// `selectBucket`. `weights` are walked in order, each weight added to a running total;
    /// the first key whose running total STRICTLY exceeds `value` (`value < prev`) wins. If the
    /// accumulated weights never cover `value` (an uncovered tail), returns `nil`.
    ///
    /// `weights` are expected ALREADY in bucket-units (`0..<10000`) — this helper performs no
    /// scaling (no `*100`) and applies no redistribution.
    static func selectBucket(weights: [(key: String, weight: Int)], value: Int) -> String? {
        var prev = 0
        for entry in weights {
            prev += entry.weight
            if value < prev {
                return entry.key
            }
        }
        return nil
    }
}
