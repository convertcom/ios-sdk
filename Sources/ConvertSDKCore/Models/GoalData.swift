// GoalData.swift
// Goal-metric keys and values for conversion events.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// The set of recognised goal-metric keys.
///
/// Exactly eight cases, verified against the JS SDK wire types (`types.gen.ts`):
/// `amount | productsCount | transactionId | customDimension1…5`. There is deliberately
/// **no** `value` case — `value` is the metric's payload, not one of its keys. Each
/// `rawValue` is the exact camelCase wire string.
///
/// `Codable` conformance is explicit so the `String` raw value encodes/decodes as the wire
/// key string (required because `GoalDataEntry` carries a `GoalDataKey` field and the
/// synthesized `Codable` for that struct needs this enum to be `Codable` too).
///
/// The raw values are intentionally left implicit: for a `String`-backed enum each case's
/// raw value defaults to its name, so `GoalDataKey.productsCount.rawValue == "productsCount"`
/// holds without the explicit `= "productsCount"` (which the `redundant_string_enum_value`
/// lint rule forbids). Every case name below is itself the exact camelCase wire string, so
/// the parity contract is preserved and `GoalDataKeyTests` asserts each `rawValue` directly.
public enum GoalDataKey: String, Codable, Sendable, CaseIterable {
    /// The monetary amount (e.g. revenue) for the conversion.
    case amount
    /// The number of products in the conversion.
    case productsCount
    /// The transaction identifier for the conversion.
    case transactionId
    /// The first custom dimension carried with the conversion.
    case customDimension1
    /// The second custom dimension carried with the conversion.
    case customDimension2
    /// The third custom dimension carried with the conversion.
    case customDimension3
    /// The fourth custom dimension carried with the conversion.
    case customDimension4
    /// The fifth custom dimension carried with the conversion.
    case customDimension5
}

/// The value of a goal metric: a number, a string, or an array of strings.
///
/// Mirrors the JS wire type `number | string | Array<string>`. Encodes and decodes as the
/// **bare** value (not wrapped in an object) via a single-value container, so a `.double`
/// emits `12.5`, a `.string` emits `"abc"`, and a `.strings` emits `["a","b"]`.
public enum GoalDataValue: Codable, Sendable {
    /// A numeric metric value.
    case double(Double)
    /// A string metric value.
    case string(String)
    /// An array-of-strings metric value.
    case strings([String])

    /// Encodes the bare underlying value into a single-value container.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .double(double):
            try container.encode(double)
        case let .string(string):
            try container.encode(string)
        case let .strings(strings):
            try container.encode(strings)
        }
    }

    /// Decodes the bare value, trying `Double`, then `String`, then `[String]`.
    ///
    /// Throws `DecodingError.dataCorrupted` when none of the three shapes match, rather
    /// than force-unwrapping or silently defaulting.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let strings = try? container.decode([String].self) {
            self = .strings(strings)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "GoalDataValue is not a Double, String, or [String]"
            )
        }
    }
}

/// Convenience map form of goal data, keyed by recognised metric key.
///
/// ```swift
/// // given a ready `context`
/// let data: GoalData = [.amount: .double(49.99), .productsCount: .double(2)]
/// await context.trackConversion("purchase-goal", goalData: data)
/// ```
public typealias GoalData = [GoalDataKey: GoalDataValue]

/// The array-of-`{key, value}` wire element form of a single goal metric.
///
/// `key` is a `GoalDataKey`; because that enum is `String`-backed it encodes/decodes as its
/// `rawValue` wire string automatically. `value` is the bare metric value. `CodingKeys` are
/// explicit (`key`, `value`) to pin the wire spelling.
public struct GoalDataEntry: Codable, Sendable {
    /// The recognised goal-metric key (encoded as its `rawValue` string).
    public let key: GoalDataKey
    /// The metric value.
    public let value: GoalDataValue

    /// Memberwise initializer.
    public init(key: GoalDataKey, value: GoalDataValue) {
        self.key = key
        self.value = value
    }

    /// Explicit wire keys for the `{key, value}` element shape.
    private enum CodingKeys: String, CodingKey {
        case key
        case value
    }
}

public extension GoalData {
    /// Maps this developer-facing key→value dictionary to the array-of-`{key, value}` wire form
    /// (`[GoalDataEntry]`) the conversion event carries. The wire schema is an ARRAY of
    /// `{key, value}` objects (per the JS SDK `types.gen.ts:2811-2820`), not a flat object, so a
    /// dictionary cannot serialize to it directly — each pair becomes one `GoalDataEntry`.
    ///
    /// The array is sorted by `key.rawValue` (ascending, lexicographic) so that repeated calls on
    /// the same `GoalData` always produce the same wire-array order regardless of Dictionary
    /// iteration order, which is nondeterministic across executions.
    func toEntries() -> [GoalDataEntry] {
        sorted { $0.key.rawValue < $1.key.rawValue }
            .map { GoalDataEntry(key: $0.key, value: $0.value) }
    }
}
