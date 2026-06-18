// EventPayload.swift
// Typed payloads carried by each internal system event, plus their wrapping enum.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Payload for `SystemEvent.ready`. Carries no data.
public struct ReadyPayload: Sendable {
    /// Creates an empty ready payload.
    public init() {}
}

/// Payload for `SystemEvent.configUpdated` — the config snapshot that was (re)loaded.
public struct ConfigUpdatedPayload: Sendable {
    /// The config snapshot that was (re)loaded; `nil` for a degraded refresh with no typed config.
    public let snapshot: ProjectConfig?

    /// Memberwise initializer.
    public init(snapshot: ProjectConfig?) {
        self.snapshot = snapshot
    }
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
    /// The SDK finished its first configuration load and is now ready to decide.
    case ready(ReadyPayload)
    /// A new configuration snapshot was loaded, carrying the updated config.
    case configUpdated(ConfigUpdatedPayload)
    /// A batch of queued tracking events was delivered to the network, carrying its size.
    case apiQueueReleased(ApiQueueReleasedPayload)
    /// A visitor was bucketed into a variation, carrying the experience/variation/visitor ids.
    case bucketing(BucketingPayload)
    /// A visitor converted on a goal, carrying the goal and visitor ids.
    case conversion(ConversionPayload)
    /// A visitor's segmentation attributes were resolved, carrying the resolved segments.
    case segments(SegmentsPayload)
    /// A location became active for the visitor, carrying its properties.
    case locationActivated(LocationActivatedPayload)
    /// A previously active location was deactivated for the visitor.
    case locationDeactivated(LocationDeactivatedPayload)
    /// The audiences a visitor belongs to were resolved, carrying their identifiers.
    case audiences(AudiencesPayload)
    /// The on-disk data store's pending queue was flushed.
    case dataStoreQueueReleased(DataStoreQueueReleasedPayload)
}
