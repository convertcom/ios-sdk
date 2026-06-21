// Feature.swift
// A feature flag resolved for a visitor, with its typed variables.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// Lifecycle status of a bucketed feature.
public enum FeatureStatus: String, Codable, Sendable, Equatable {
    /// The feature is on for this visitor — its variables carry the bucketed values.
    case enabled
    /// The feature is off for this visitor — the default, no-variables state.
    case disabled
}

/// A single feature variable value, type-tagged to mirror the five JS variable types.
///
/// JSON variables are carried as `Data` rather than a decoded `Any` so the case stays
/// genuinely `Sendable` (no `@unchecked`); callers decode the bytes at the use site.
///
/// `Codable` is written by hand (see `CodingKeys`, `init(from:)`, `encode(to:)` below)
/// because an enum with heterogeneous associated values has no synthesized form that
/// round-trips. The wire shape is a keyed object with a `type` discriminator string
/// (`"boolean"`/`"integer"`/`"float"`/`"string"`/`"json"` — the JS variable-type
/// vocabulary) and a `value` carrying the associated payload. For `.json`, the `Data` is
/// encoded via `Data`'s default `Codable` (a base64 `String`), which round-trips the exact
/// bytes losslessly. `Equatable` synthesizes (every associated type is `Equatable`).
public enum FeatureVariable: Codable, Sendable, Equatable {
    /// A boolean variable.
    case boolean(Bool)
    /// An integer variable.
    case integer(Int)
    /// A floating-point variable.
    case float(Double)
    /// A string variable.
    case string(String)
    /// A JSON variable, carried as raw `Data` for callers to decode at the use site.
    case json(Data)

    /// Explicit wire keys: a `type` discriminator and the `value` payload. Pinned by hand
    /// (no key-strategy, no snake_case) so the form never drifts.
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    /// The discriminator strings, matching the JS variable-type vocabulary.
    private enum TypeTag: String, Codable {
        case boolean
        case integer
        case float
        case string
        case json
    }

    /// Decodes a feature variable from its `{type, value}` wire object, dispatching on the
    /// `type` discriminator.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(TypeTag.self, forKey: .type)
        switch tag {
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .integer:
            self = .integer(try container.decode(Int.self, forKey: .value))
        case .float:
            self = .float(try container.decode(Double.self, forKey: .value))
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .json:
            self = .json(try container.decode(Data.self, forKey: .value))
        }
    }

    /// Encodes a feature variable as its `{type, value}` wire object, writing the matching
    /// `type` discriminator and payload.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .boolean(boolean):
            try container.encode(TypeTag.boolean, forKey: .type)
            try container.encode(boolean, forKey: .value)
        case let .integer(integer):
            try container.encode(TypeTag.integer, forKey: .type)
            try container.encode(integer, forKey: .value)
        case let .float(float):
            try container.encode(TypeTag.float, forKey: .type)
            try container.encode(float, forKey: .value)
        case let .string(string):
            try container.encode(TypeTag.string, forKey: .type)
            try container.encode(string, forKey: .value)
        case let .json(data):
            try container.encode(TypeTag.json, forKey: .type)
            try container.encode(data, forKey: .value)
        }
    }
}

/// A feature flag resolved for a visitor, carrying its status and typed variables.
///
/// ```swift
/// // given a ready `context`
/// let feature = await context.runFeature("new-checkout")
/// if feature.status == .enabled { /* the feature is on for this visitor */ }
/// ```
public struct Feature: Codable, Sendable, Equatable {
    /// Stable identifier of the feature.
    public let id: String
    /// Human-readable key of the feature.
    public let key: String
    /// Whether the feature is enabled or disabled for this visitor.
    public let status: FeatureStatus
    /// Variables keyed by variable name.
    public let variables: [String: FeatureVariable]

    /// Memberwise initializer.
    public init(id: String, key: String, status: FeatureStatus, variables: [String: FeatureVariable]) {
        self.id = id
        self.key = key
        self.status = status
        self.variables = variables
    }

    /// Explicit wire keys (no snake_case, no derived spellings). The synthesized
    /// `init(from:)`/`encode(to:)` use these pinned keys.
    private enum CodingKeys: String, CodingKey {
        case id
        case key
        case status
        case variables
    }

    /// Builds a disabled feature with an empty `id` and no variables.
    ///
    /// The canonical "feature off" value: any `variable(_:as:)` lookup returns `nil`
    /// because `variables` is empty.
    public static func disabled(key: String) -> Feature {
        Feature(id: "", key: key, status: .disabled, variables: [:])
    }

    /// Non-throwing typed accessor for a feature variable (AOD-6 — never throws).
    ///
    /// ```swift
    /// // given a resolved `feature`
    /// let color = feature.variable("buttonColor", as: String.self) ?? "blue"
    /// ```
    ///
    /// Returns `nil` when the key is unknown, or when the stored case's associated value
    /// is not of the requested type `T`. For `.json`, the associated `Data` is returned
    /// only when `T` is `Data`. No force-unwraps: every branch casts with `as?`.
    public func variable<T>(_ key: String, as type: T.Type) -> T? {
        guard let value = variables[key] else { return nil }
        switch value {
        case let .boolean(boolean):
            return boolean as? T
        case let .integer(integer):
            return integer as? T
        case let .float(float):
            return float as? T
        case let .string(string):
            return string as? T
        case let .json(data):
            return data as? T
        }
    }
}
