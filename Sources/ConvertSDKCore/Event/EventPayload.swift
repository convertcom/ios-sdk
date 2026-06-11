// EventPayload.swift
// Typed payloads carried by each internal system event, plus their wrapping enum.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Payload for `SystemEvent.ready`. Carries no data.
public struct ReadyPayload: Sendable {
    /// Creates an empty ready payload.
    public init() {}
}

/// Payload for `SystemEvent.configUpdated`. Carries no data.
public struct ConfigUpdatedPayload: Sendable {
    /// Creates an empty config-updated payload.
    public init() {}
}

/// Payload for `SystemEvent.bucketing` — the visitor/variation pairing that was resolved.
public struct BucketingPayload: Sendable {
    /// Identifier of the bucketed experience.
    public let experienceId: String
    /// Identifier of the variation the visitor was bucketed into.
    public let variationId: String
    /// Identifier of the bucketed visitor.
    public let visitorId: String

    /// Memberwise initializer.
    public init(experienceId: String, variationId: String, visitorId: String) {
        self.experienceId = experienceId
        self.variationId = variationId
        self.visitorId = visitorId
    }
}

/// Payload for `SystemEvent.conversion` — the goal a visitor converted on.
public struct ConversionPayload: Sendable {
    /// Identifier of the converted goal.
    public let goalId: String
    /// Identifier of the converting visitor.
    public let visitorId: String

    /// Memberwise initializer.
    public init(goalId: String, visitorId: String) {
        self.goalId = goalId
        self.visitorId = visitorId
    }
}

/// Payload for `SystemEvent.segments` — resolved segmentation attributes for a visitor.
public struct SegmentsPayload: Sendable {
    /// Identifier of the segmented visitor.
    public let visitorId: String
    /// Resolved segmentation attributes.
    public let segments: Segments

    /// Memberwise initializer.
    public init(visitorId: String, segments: Segments) {
        self.visitorId = visitorId
        self.segments = segments
    }
}

/// Payload for `SystemEvent.apiQueueReleased` — the size of the delivered batch.
public struct ApiQueueReleasedPayload: Sendable {
    /// Number of events in the delivered batch.
    public let eventCount: Int

    /// Memberwise initializer.
    public init(eventCount: Int) {
        self.eventCount = eventCount
    }
}

/// Payload for `SystemEvent.dataStoreQueueReleased`. Carries no data.
public struct DataStoreQueueReleasedPayload: Sendable {
    /// Creates an empty data-store-queue-released payload.
    public init() {}
}

/// Payload for `SystemEvent.locationActivated` — properties of the activated location.
public struct LocationActivatedPayload: Sendable {
    /// Properties describing the activated location.
    public let properties: [String: String]

    /// Memberwise initializer.
    public init(properties: [String: String]) {
        self.properties = properties
    }
}

/// Payload for `SystemEvent.locationDeactivated`. Carries no data.
public struct LocationDeactivatedPayload: Sendable {
    /// Creates an empty location-deactivated payload.
    public init() {}
}

/// Payload for `SystemEvent.audiences` — audiences resolved for a visitor.
public struct AudiencesPayload: Sendable {
    /// Identifiers of the audiences the visitor belongs to.
    public let audienceIds: [String]
    /// Identifier of the visitor.
    public let visitorId: String

    /// Memberwise initializer.
    public init(audienceIds: [String], visitorId: String) {
        self.audienceIds = audienceIds
        self.visitorId = visitorId
    }
}

/// The type-tagged payload delivered alongside a `SystemEvent`.
///
/// One case per payload struct, matching the firing `SystemEvent` member. Every
/// associated value is a genuine value-type `Sendable` (`String`, `Int`, `[String]`,
/// `[String: String]`, `Segments`) — no `@unchecked Sendable`.
public enum EventPayloadValue: Sendable {
    case ready(ReadyPayload)
    case configUpdated(ConfigUpdatedPayload)
    case apiQueueReleased(ApiQueueReleasedPayload)
    case bucketing(BucketingPayload)
    case conversion(ConversionPayload)
    case segments(SegmentsPayload)
    case locationActivated(LocationActivatedPayload)
    case locationDeactivated(LocationDeactivatedPayload)
    case audiences(AudiencesPayload)
    case dataStoreQueueReleased(DataStoreQueueReleasedPayload)
}
