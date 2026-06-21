//
//  PolymorphicSentinels.swift
//  ConvertSwiftSDKCore
//
//  HAND-AUTHORED — the resilience companion to the generated config types in
//  ConfigSchemas.swift. This file is the LCD-sentinel decode layer and is maintained
//  BY HAND; it is intentionally NOT produced by Scripts/generate-config-types/run.sh and
//  must not be machine-overwritten. It lives under Generated/ only so it sits beside the
//  types it wraps; it is the single hand-maintained exception in that directory.
//
//  ── Why this layer exists (R5 / FR60 / AR16) ────────────────────────────────────────
//  The Convert CDN strips `oneOf + discriminator` config payloads down to a
//  discriminator-ABSENT ("LCD") shape for disabled / unconfigured projects, and may emit
//  NEW discriminator values before this SDK knows about them. The generated `oneOf` enums
//  in ConfigSchemas.swift THROW in both situations: `DecodingError.keyNotFound` when the
//  discriminator key is absent, and `DecodingError.unknownOneOfDiscriminator` (also a
//  keyNotFound) when the value is unrecognised. A raw `JSONDecoder.decode` of a config
//  containing such a payload would therefore throw and the SDK would fail to load config.
//
//  Approach A (extend the generated enums with a passthrough case) is impossible: the
//  generated enums are `@frozen` and non-extensible. Approach B (MANDATED) wraps each
//  config-reachable `oneOf` in a generic discriminated container, `SentinelWrapped<Known>`,
//  whose decoder tries the generated type and, on ANY thrown error, falls back to a
//  structure-preserving `.sentinel` that carries the raw payload so the config cache can
//  round-trip an unknown / LCD payload without corrupting it.
//
//  ── Affected schemas (AR16: DERIVED from discriminator-manifest.json, NOT hand-listed) ─
//  The list below is the spec-derived source of truth from
//  Sources/ConvertSwiftSDKCore/Generated/discriminator-manifest.json. Each entry: the wrapped
//  generated schema (under `Components.Schemas.`), the wire discriminator property, its
//  known discriminator values, and the typealias exposed here. The sentinel case for every
//  wrapper is `SentinelWrapped.sentinel`.
//
//    1. ConfigGoal                     — wire `type`        — values: advanced, clicks_element,
//         clicks_link, code_trigger, dom_interaction, ga_import, revenue, scroll_percentage,
//         submits_form, visits_page                                  → ConfigGoalOrSentinel
//    2. ExperienceChangeServing        — wire `type`        — values: customCode, defaultCode,
//         defaultCodeMultipage, defaultRedirect, fullStackFeature, richStructure
//                                                                    → ExperienceChangeServingOrSentinel
//    3. ExperienceIntegrationGAServing — wire `type`        — values: ga3, ga4
//                                                                    → ExperienceIntegrationGAServingOrSentinel
//    4. GA_Settings                    — wire `type`        — values: ga3, ga4
//                                                                    → GASettingsOrSentinel
//    5. LocationTrigger                — wire `type`        — values: callback, dom_element,
//         manual, upon_run                                           → LocationTriggerOrSentinel
//    6. NumericOutlier                 — wire `detection_type` — values: min_max, none, percentile
//                                                                    → NumericOutlierOrSentinel
//    7. RuleElement                    — wire `rule_type`   — values: avg_time_page … weather_condition
//         (50 values; see manifest)                                 → RuleElementOrSentinel
//    8. RuleElementAudience            — wire `rule_type`   — values: avg_time_page … weather_condition
//         (52 values; see manifest)                                 → RuleElementAudienceOrSentinel
//
//  ── Round-trip fidelity guarantee ───────────────────────────────────────────────────
//  The `.sentinel` arm preserves the payload as `JSONValue` and re-encodes it on the way
//  out. The guarantee is CANONICAL-EQUIVALENCE, not literal byte-identity: object member
//  order is not recoverable through Swift's `Codable` keyed container (Foundation's
//  `allKeys` does not preserve source order), so a re-encode may reorder object keys.
//  Numbers are carried as `Double`. Consumers that need to compare a re-encoded sentinel
//  against the original MUST canonicalise both sides through the same serialiser
//  configuration (e.g. `JSONSerialization` / `JSONEncoder` with `.sortedKeys`); the value,
//  type, nesting, array order, and key SET are all preserved exactly. This is the fidelity
//  the config cache requires (it never needs to reproduce arbitrary source key order, only
//  to avoid corrupting the payload's content).
//

import Foundation

// MARK: - JSONValue

/// A structure-preserving carrier for an arbitrary JSON payload.
///
/// Used by `SentinelWrapped.sentinel` to hold a payload the generated `oneOf` could not
/// decode (LCD / unknown discriminator) so it can be re-emitted on encode. See the file
/// header for the exact round-trip fidelity guarantee.
///
/// Objects are stored as ordered key/value pairs purely so a single decoded value has a
/// stable internal representation; source member order is NOT recoverable via `Codable`
/// and callers must canonicalise (sorted keys) when comparing re-encoded output.
public indirect enum JSONValue: Codable, Sendable, Hashable {
    case object([Pair])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// One member of a JSON object. A named pair type (rather than a tuple) is required so
    /// the enclosing `enum` can be `Hashable`/`Equatable`: Swift does not synthesise those
    /// conformances for tuple payloads.
    public struct Pair: Codable, Sendable, Hashable {
        public let key: String
        public let value: JSONValue

        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    /// Decodes any JSON node. Container kinds are attempted from most to least specific so
    /// that, e.g., a `bool` is never misread as a `number`.
    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
            var pairs: [Pair] = []
            pairs.reserveCapacity(keyed.allKeys.count)
            for key in keyed.allKeys {
                let value = try keyed.decode(JSONValue.self, forKey: key)
                pairs.append(Pair(key: key.stringValue, value: value))
            }
            self = .object(pairs)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            if let count = unkeyed.count {
                values.reserveCapacity(count)
            }
            while !unkeyed.isAtEnd {
                values.append(try unkeyed.decode(JSONValue.self))
            }
            self = .array(values)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try single.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .object(pairs):
            var keyed = encoder.container(keyedBy: DynamicKey.self)
            for pair in pairs {
                guard let codingKey = DynamicKey(stringValue: pair.key) else { continue }
                try keyed.encode(pair.value, forKey: codingKey)
            }
        case let .array(values):
            var unkeyed = encoder.unkeyedContainer()
            for value in values {
                try unkeyed.encode(value)
            }
        case let .string(value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case let .number(value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case let .bool(value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .null:
            var single = encoder.singleValueContainer()
            try single.encodeNil()
        }
    }

    /// A `CodingKey` whose string value is supplied at runtime, so an object with arbitrary
    /// member names can be decoded/encoded without a compile-time key enum.
    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}

// MARK: - SentinelWrapped

/// A discriminated wrapper that decodes a generated `oneOf` type resiliently.
///
/// On decode it FIRST captures the raw payload as `JSONValue`, then attempts to decode the
/// wrapped `Known` type from the same decoder. If `Known(from:)` throws for ANY reason —
/// notably the generated `oneOf`'s `DecodingError.keyNotFound` (discriminator absent) and
/// `DecodingError.unknownOneOfDiscriminator` (unrecognised value) — it falls back to
/// `.sentinel`, carrying the captured payload. It therefore NEVER throws on a well-formed
/// JSON node, satisfying the "never throw, never crash" invariants of the LCD contract.
///
/// The wrapper's `try`/`catch` is the SENTINEL MECHANISM, scoped to this initialiser. It is
/// deliberately broad (it must absorb any decode failure of an unknown future variant) and
/// is NOT an SDK-boundary "catch-and-drop-config" workaround.
public enum SentinelWrapped<Known: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    /// The payload decoded into a known generated variant.
    case known(Known)
    /// The payload could not be decoded into a known variant (LCD / unknown discriminator);
    /// the raw structured payload is retained for a content-preserving round-trip.
    case sentinel(JSONValue)

    public init(from decoder: any Decoder) throws {
        // Capture the raw payload first so the sentinel arm can round-trip it. This decode
        // of a structural JSONValue does not consume the decoder destructively, so the
        // subsequent `Known(from:)` attempt reads the same node.
        let captured = try JSONValue(from: decoder)
        do {
            self = .known(try Known(from: decoder))
        } catch {
            self = .sentinel(captured)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .known(value):
            try value.encode(to: encoder)
        case let .sentinel(payload):
            try payload.encode(to: encoder)
        }
    }
}

// MARK: - Config-reachable oneOf wrappers (DERIVED from discriminator-manifest.json)

/// `ConfigGoal` with LCD/unknown-discriminator resilience. Wire discriminator: `type`.
public typealias ConfigGoalOrSentinel = SentinelWrapped<Components.Schemas.ConfigGoal>

/// `ExperienceChangeServing` with resilience. Wire discriminator: `type`.
public typealias ExperienceChangeServingOrSentinel =
    SentinelWrapped<Components.Schemas.ExperienceChangeServing>

/// `ExperienceIntegrationGAServing` with resilience. Wire discriminator: `type`.
public typealias ExperienceIntegrationGAServingOrSentinel =
    SentinelWrapped<Components.Schemas.ExperienceIntegrationGAServing>

/// `GA_Settings` with resilience. Wire discriminator: `type`.
public typealias GASettingsOrSentinel = SentinelWrapped<Components.Schemas.GA_Settings>

/// `LocationTrigger` with resilience. Wire discriminator: `type`.
public typealias LocationTriggerOrSentinel = SentinelWrapped<Components.Schemas.LocationTrigger>

/// `NumericOutlier` with resilience. Wire discriminator: `detection_type`.
public typealias NumericOutlierOrSentinel = SentinelWrapped<Components.Schemas.NumericOutlier>

/// `RuleElement` with resilience. Wire discriminator: `rule_type`.
public typealias RuleElementOrSentinel = SentinelWrapped<Components.Schemas.RuleElement>

/// `RuleElementAudience` with resilience. Wire discriminator: `rule_type`.
public typealias RuleElementAudienceOrSentinel =
    SentinelWrapped<Components.Schemas.RuleElementAudience>
