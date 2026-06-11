// BucketedFeature.swift
// A feature flag resolved for a visitor, with its typed variables.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Lifecycle status of a bucketed feature.
public enum FeatureStatus: String, Sendable {
    case enabled
    case disabled
}

/// A single feature variable value, type-tagged to mirror the five JS variable types.
///
/// JSON variables are carried as `Data` rather than a decoded `Any` so the case stays
/// genuinely `Sendable` (no `@unchecked`); callers decode the bytes at the use site.
public enum FeatureVariable: Sendable {
    case boolean(Bool)
    case integer(Int)
    case float(Double)
    case string(String)
    case json(Data)
}

/// A feature flag resolved for a visitor, carrying its status and typed variables.
public struct BucketedFeature: Sendable {
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

    /// Non-throwing typed accessor for a feature variable (AOD-6 — never throws).
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
