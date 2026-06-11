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

    /// Explicit camelCase wire keys.
    private enum CodingKeys: String, CodingKey {
        case bucketing
        case goalTriggered
        case segments
        case locations
    }
}
