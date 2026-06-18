// Variation.swift
// The variation a visitor is bucketed into for an experience.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// A single variation of an experience, as resolved by bucketing.
///
/// ```swift
/// // given a ready `context`
/// if let variation = await context.runExperience("pricing-test") {
///     print("\(variation.experienceKey) → \(variation.key)")
/// }
/// ```
///
/// `id` is modelled as `String` even though the JS SDK uses an integer — this keeps the
/// type forward-compatible with the generated wire types (which widen identifiers) and
/// avoids a lossy `Int`/`Int64` choice at the model boundary.
///
/// `CodingKeys` are declared explicitly so the camelCase wire spelling
/// (`experienceId`, `experienceKey`) is pinned and never drifts to a derived form.
public struct Variation: Codable, Sendable, Identifiable {
    /// Stable identifier of the variation.
    public let id: String
    /// Human-readable key of the variation.
    public let key: String
    /// Identifier of the experience this variation belongs to.
    public let experienceId: String
    /// Human-readable key of the experience this variation belongs to.
    public let experienceKey: String

    /// Memberwise initializer.
    public init(id: String, key: String, experienceId: String, experienceKey: String) {
        self.id = id
        self.key = key
        self.experienceId = experienceId
        self.experienceKey = experienceKey
    }

    /// Explicit camelCase wire keys (no snake_case, no derived spellings).
    private enum CodingKeys: String, CodingKey {
        case id
        case key
        case experienceId
        case experienceKey
    }
}
