// Sources/ConvertSwiftSDKCore/Bucketing/AnchoredBucketing.swift
// ANCHORED bucketing layout (qs-01, cross-SDK bucketing contract v12) — Phase 2 / GREEN.
//
// Selected per experience by `BucketingManager.bucketVersionGated(...)`: `experience.version > 11`
// routes here; `version <= 11` / missing / non-numeric stays on the EXISTING packed walk in
// `BucketingManager.bucket(...)` (untouched, AC6). Spec of record (do NOT re-derive the algorithm
// here): `2026-06-09-convert-ios-sdk/qs-01-anchored-bucketing-layout.md` — mirrors the JS
// reference exactly (`data-manager.ts:591-610` `_buildVariationAllocations`,
// `bucketing-manager.ts:152-204` `getBucketRanges`/`selectBucketAnchored`):
//
//   allocations = experience.variations (config order), entries with no `id` DROPPED (never
//     counted toward totalWeight — matches `_buildVariationAllocations`'s `if (!variation?.id)
//     return allocations`) →
//     { id, allocation: isNaN(ta) || ta absent ? 100.0 : ta,
//       active: (status == nil || status == RUNNING) && (ta > 0 || isNaN(ta) || ta absent) }
//   totalWeight = sum of allocation over ALL remaining entries (active AND inactive)
//   if totalWeight <= 0 → not bucketed
//   cumWeight = 0
//   for each entry in order:
//     anchor = (cumWeight / totalWeight) * 10000.0
//     width  = entry.active ? entry.allocation * 100.0 : 0.0
//     if value >= anchor && value < anchor + width → return entry.id
//     cumWeight += entry.allocation
//   return nil
//
// All arithmetic is `Double` (IEEE754) throughout, matching JS `Number` semantics — no
// `Decimal`/`Float80`. `value` is the shared bucket-value projection (seed 9999, same
// MurmurHash3 + scaling as the packed path) — reused unchanged, never recomputed here.

import Foundation

/// Namespace for the ANCHORED bucketing pass (contract v12+). Stateless — a pure selector, mirroring
/// `BucketingManager.selectBucket` for the packed pass, so it stays trivially testable with no
/// collaborators (no `EventSink`/`Logger`; the caller owns mapping the result back onto a
/// `Variation` and the tracking enqueue).
internal enum AnchoredBucketing {
    /// One variation's resolved allocation weight and active/inactive flag under the anchored
    /// layout — a named struct (not a tuple) so `large_tuple` stays satisfied.
    private struct Allocation {
        let id: String
        let allocation: Double
        let active: Bool
    }

    /// Selects the variation id that `value` (a `0..<10000` bucket-unit, computed identically to
    /// the packed path — hash/seed/scaling are untouched) falls into under the ANCHORED layout.
    ///
    /// - Parameters:
    ///   - variations: The experience's variations, in CONFIG ORDER, **unfiltered** — every entry
    ///     (active and inactive, with or without a `traffic_allocation`) must be passed through;
    ///     the anchored algorithm itself interprets active/inactive and NaN/absent allocation,
    ///     unlike the packed pass's pre-filtered `eligible` walk.
    ///   - value: The visitor's bucket value (`0..<10000`).
    /// - Returns: The selected variation id, or `nil` when not bucketed.
    static func selectBucket(
        variations: [Components.Schemas.ExperienceVariationConfig],
        value: Int
    ) -> String? {
        let allocations = buildAllocations(variations)
        let totalWeight = allocations.reduce(0.0) { $0 + $1.allocation }
        guard totalWeight > 0 else {
            return nil
        }

        let doubleValue = Double(value)
        var cumWeight = 0.0
        for entry in allocations {
            let anchor = (cumWeight / totalWeight) * Double(Defaults.maxTraffic)
            let width = entry.active ? entry.allocation * 100.0 : 0.0
            if doubleValue >= anchor && doubleValue < anchor + width {
                return entry.id
            }
            cumWeight += entry.allocation
        }
        return nil
    }

    /// Builds the per-variation `{id, allocation, active}` triples (config order, entries with no
    /// `id` dropped) that `selectBucket` walks — the direct mirror of the JS reference's
    /// `_buildVariationAllocations`.
    private static func buildAllocations(
        _ variations: [Components.Schemas.ExperienceVariationConfig]
    ) -> [Allocation] {
        variations.compactMap { variation in
            guard let id = variation.id else {
                return nil
            }
            let rawAllocation = variation.traffic_allocation
            let isDefaulted = rawAllocation == nil || rawAllocation?.isNaN == true
            let allocation = isDefaulted ? 100.0 : (rawAllocation ?? 100.0)
            let statusActive = variation.status == nil || variation.status == .running
            let active = statusActive && (allocation > 0 || isDefaulted)
            return Allocation(id: id, allocation: allocation, active: active)
        }
    }
}
