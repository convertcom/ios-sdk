// Sources/ConvertSwiftSDKCore/Bucketing/AnchoredBucketing.swift
// ANCHORED bucketing layout (qs-01, cross-SDK bucketing contract v12) — Phase 1 / RED SCAFFOLD.
//
// Selected per experience by `BucketingManager.bucketVersionGated(...)`: `experience.version > 11`
// routes here; `version <= 11` / missing / non-numeric stays on the EXISTING packed walk in
// `BucketingManager.bucket(...)` (untouched, AC6). Spec of record (do NOT re-derive the algorithm
// here): `2026-06-09-convert-ios-sdk/qs-01-anchored-bucketing-layout.md` —
//
//   allocations = experience.variations (config order) →
//     { id, allocation: isNaN(ta) ? 100.0 : ta,
//       active: (status ? status == RUNNING : true) && (ta > 0 || isNaN(ta)) }
//   totalWeight = sum of allocation over ALL entries (active AND inactive)
//   if totalWeight <= 0 → not bucketed
//   cumWeight = 0
//   for each entry in order:
//     anchor = (cumWeight / totalWeight) * 10000
//     width  = entry.active ? entry.allocation * 100 : 0
//     if anchor <= value < anchor + width → return entry.id
//     cumWeight += entry.allocation
//   return nil
//
// ── PHASE 1 (RED) — DELIBERATE STUB ─────────────────────────────────────────────────────────
// `selectBucket(variations:value:)` always returns `nil` (not-bucketed) below. This is NOT the
// real anchored algorithm — Phase 2 (GREEN) fills in the allocation/anchor/width walk per the
// pseudocode above. The signature is final; only the body changes in Phase 2, so callers (the
// version gate in `BucketingManager` and every RED test) never need to change shape.

import Foundation

/// Namespace for the ANCHORED bucketing pass (contract v12+). Stateless — a pure selector, mirroring
/// `BucketingManager.selectBucket` for the packed pass, so it stays trivially testable with no
/// collaborators (no `EventSink`/`Logger`; the caller owns mapping the result back onto a
/// `Variation` and the tracking enqueue).
internal enum AnchoredBucketing {
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
    ///
    /// PHASE 1 (RED): deliberately unimplemented — always returns `nil` until Phase 2 (GREEN)
    /// builds the allocation/anchor/width walk described above.
    static func selectBucket(
        variations: [Components.Schemas.ExperienceVariationConfig],
        value: Int
    ) -> String? {
        nil
    }
}
