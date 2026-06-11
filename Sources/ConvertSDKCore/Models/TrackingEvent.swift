// TrackingEvent.swift
// The canonical on-the-wire tracking payload (FR68 precursor).
// Foundation-only — part of the pure-logic ConvertSDKCore target.
//
// Wire-parity landmines guarded here (AR13):
//   * Every struct declares explicit `CodingKeys` with camelCase wire spellings.
//   * No `keyEncodingStrategy`/`.convertToSnakeCase` is ever used — the test encoder
//     relies on the default key strategy, and snake_case keys must never leak.
//   * The entry's `data` is a FLAT object: the bucketing/conversion fields appear as
//     direct siblings under the `data` key, not nested one level deeper.

import Foundation

/// The top-level tracking payload posted to the Convert serving API.
///
/// `enrichData` is always `false` and `source` is always `"ios-sdk"` — both are hardcoded
/// in the initializer (AOD-1, APB5) and are **not** settable parameters. They remain stored
/// properties so they encode onto the wire.
public struct TrackingEvent: Codable, Sendable {
    /// Convert account identifier.
    public let accountId: String
    /// Convert project identifier.
    public let projectId: String
    /// Always `false` for the iOS SDK — backend enrichment is not requested.
    public let enrichData: Bool
    /// Always `"ios-sdk"` — identifies the originating SDK.
    public let source: String
    /// The visitors whose events this payload carries.
    public let visitors: [Visitor]

    /// Creates a tracking event. `enrichData` and `source` are hardcoded, not parameters.
    public init(accountId: String, projectId: String, visitors: [Visitor]) {
        self.accountId = accountId
        self.projectId = projectId
        self.enrichData = false
        self.source = "ios-sdk"
        self.visitors = visitors
    }

    /// Explicit camelCase wire keys.
    private enum CodingKeys: String, CodingKey {
        case accountId
        case projectId
        case enrichData
        case source
        case visitors
    }
}

/// A single visitor and their events within a ``TrackingEvent``.
public struct Visitor: Codable, Sendable {
    /// Stable visitor identifier.
    public let visitorId: String
    /// Free-form segmentation key/value pairs for this visitor.
    public let segments: [String: String]
    /// The events recorded for this visitor.
    public let events: [TrackingEventEntry]

    /// Memberwise initializer.
    public init(visitorId: String, segments: [String: String], events: [TrackingEventEntry]) {
        self.visitorId = visitorId
        self.segments = segments
        self.events = events
    }

    /// Explicit camelCase wire keys.
    private enum CodingKeys: String, CodingKey {
        case visitorId
        case segments
        case events
    }
}

/// One event entry: an `eventType` tag plus a FLAT `data` payload.
///
/// Callers build entries through the ``bucketing(_:)`` / ``conversion(_:)`` factories and
/// never touch the internal payload representation. The wire shape is
/// `{"eventType": "bucketing"|"conversion", "data": { …flat fields… }}` — never the legacy
/// `viewExp` / `hitGoal` / `tr` event names.
public struct TrackingEventEntry: Codable, Sendable {
    /// Internal payload, type-tagged by event kind. Kept private so the public surface is
    /// the two factories plus the encoded wire shape — and so `eventType` has a single
    /// source of truth (this enum) rather than a separately stored string that could drift.
    private enum Payload: Sendable {
        case bucketing(BucketingEventData)
        case conversion(ConversionEventData)

        /// The wire `eventType` string for this payload.
        var eventType: String {
            switch self {
            case .bucketing: return "bucketing"
            case .conversion: return "conversion"
            }
        }
    }

    private let payload: Payload

    private init(payload: Payload) {
        self.payload = payload
    }

    /// The event-type tag (`"bucketing"` or `"conversion"`), derived from the payload.
    public var eventType: String { payload.eventType }

    /// Builds a bucketing entry (`eventType == "bucketing"`).
    public static func bucketing(_ data: BucketingEventData) -> TrackingEventEntry {
        TrackingEventEntry(payload: .bucketing(data))
    }

    /// Builds a conversion entry (`eventType == "conversion"`).
    public static func conversion(_ data: ConversionEventData) -> TrackingEventEntry {
        TrackingEventEntry(payload: .conversion(data))
    }

    /// Explicit wire keys: the tag and the flat data object.
    private enum CodingKeys: String, CodingKey {
        case eventType
        case data
    }

    /// Encodes the tag, then the payload struct directly under `data` (flat object).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(payload.eventType, forKey: .eventType)
        switch payload {
        case let .bucketing(data):
            try container.encode(data, forKey: .data)
        case let .conversion(data):
            try container.encode(data, forKey: .data)
        }
    }

    /// Decodes by branching on `eventType`; an unrecognised tag throws `dataCorrupted`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let eventType = try container.decode(String.self, forKey: .eventType)
        switch eventType {
        case "bucketing":
            let data = try container.decode(BucketingEventData.self, forKey: .data)
            self.payload = .bucketing(data)
        case "conversion":
            let data = try container.decode(ConversionEventData.self, forKey: .data)
            self.payload = .conversion(data)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.eventType,
                in: container,
                debugDescription: "Unknown eventType \"\(eventType)\""
            )
        }
    }
}

/// The flat data payload of a bucketing entry.
public struct BucketingEventData: Codable, Sendable {
    /// Experience the visitor was bucketed into.
    public let experienceId: String
    /// Variation the visitor was bucketed into.
    public let variationId: String

    /// Memberwise initializer.
    public init(experienceId: String, variationId: String) {
        self.experienceId = experienceId
        self.variationId = variationId
    }

    /// Explicit camelCase wire keys.
    private enum CodingKeys: String, CodingKey {
        case experienceId
        case variationId
    }
}

/// The flat data payload of a conversion entry.
///
/// `goalData` and `bucketingData` default to `nil` and, being optional, are omitted from
/// the encoded JSON when absent (synthesized `encodeIfPresent` behavior — no manual encode
/// needed). `CodingKeys` are explicit to pin the camelCase wire spelling.
public struct ConversionEventData: Codable, Sendable {
    /// Goal that was converted.
    public let goalId: String
    /// Optional per-goal metric data, as an array of `{key, value}` entries.
    public let goalData: [GoalDataEntry]?
    /// Optional bucketing context (experience ID → variation ID).
    public let bucketingData: [String: String]?

    /// Memberwise initializer; `goalData` and `bucketingData` default to `nil`.
    public init(
        goalId: String,
        goalData: [GoalDataEntry]? = nil,
        bucketingData: [String: String]? = nil
    ) {
        self.goalId = goalId
        self.goalData = goalData
        self.bucketingData = bucketingData
    }

    /// Explicit camelCase wire keys.
    private enum CodingKeys: String, CodingKey {
        case goalId
        case goalData
        case bucketingData
    }
}
