// StoreData.swift
// Persisted per-visitor bucketing/goal/segment state.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// The persisted per-visitor state used to dedupe and enrich tracking.
///
/// `CodingKeys` are explicit to pin the camelCase wire spelling (`goalTriggered`).
public struct StoreData: Codable, Sendable {
    /// Bucketing assignments, keyed by experience ID to the chosen variation ID.
    public let bucketing: [String: String]
    /// Per-goal dedup flags, keyed by goal ID to whether it has already been triggered.
    public let goalTriggered: [String: Bool]
    /// Segmentation attributes for the visitor.
    public let segments: Segments
    /// Resolved location assignments, keyed by location identifier.
    public let locations: [String: String]

    /// Memberwise initializer.
    public init(
        bucketing: [String: String],
        goalTriggered: [String: Bool],
        segments: Segments,
        locations: [String: String]
    ) {
        self.bucketing = bucketing
        self.goalTriggered = goalTriggered
        self.segments = segments
        self.locations = locations
    }

    /// Decodes a `StoreData` while tolerating persisted state from older SDKs (AC6 / FR51 / NFR13).
    ///
    /// `segments` and `locations` were added after the original schema, so a JSON blob written by an
    /// SDK ≤ 4.4 lacks those keys. The synthesized decoder calls `decode(_:forKey:)` for these
    /// non-optional fields and would throw `keyNotFound` on such a payload. Every field is decoded via
    /// `decodeIfPresent` and defaulted (`bucketing`/`goalTriggered`/`locations` to `[:]`, `segments`
    /// to `Segments()`) so an upgrade never discards a visitor's sticky state by failing to decode.
    /// Encoding stays on the synthesized encoder — the wire shape is unchanged.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bucketing = try container.decodeIfPresent([String: String].self, forKey: .bucketing) ?? [:]
        self.goalTriggered = try container.decodeIfPresent([String: Bool].self, forKey: .goalTriggered) ?? [:]
        self.segments = try container.decodeIfPresent(Segments.self, forKey: .segments) ?? Segments()
        self.locations = try container.decodeIfPresent([String: String].self, forKey: .locations) ?? [:]
    }

    /// Explicit camelCase wire keys.
    private enum CodingKeys: String, CodingKey {
        case bucketing
        case goalTriggered
        case segments
        case locations
    }
}
