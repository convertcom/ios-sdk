// Segments.swift
// Visitor segmentation attributes carried on the tracking payload.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Visitor segmentation attributes.
///
/// Every field is optional so callers populate only what they have. `CodingKeys` are
/// declared explicitly to pin the camelCase wire spelling — in particular `visitorType`
/// and `customSegments` must never serialize as `visitor_type` / `custom_segments`.
/// Optional fields that are `nil` are omitted from the encoded JSON (synthesized
/// `encodeIfPresent` behavior).
public struct Segments: Codable, Sendable, Equatable {
    /// Visitor country.
    public var country: String?
    /// Visitor browser.
    public var browser: String?
    /// Visitor device.
    public var devices: String?
    /// Acquisition source.
    public var source: String?
    /// Acquisition campaign.
    public var campaign: String?
    /// Visitor type (e.g. new vs returning).
    public var visitorType: String?
    /// Free-form custom segment identifiers.
    public var customSegments: [String]?

    /// Memberwise initializer; every parameter defaults to `nil` so callers omit fields.
    public init(
        country: String? = nil,
        browser: String? = nil,
        devices: String? = nil,
        source: String? = nil,
        campaign: String? = nil,
        visitorType: String? = nil,
        customSegments: [String]? = nil
    ) {
        self.country = country
        self.browser = browser
        self.devices = devices
        self.source = source
        self.campaign = campaign
        self.visitorType = visitorType
        self.customSegments = customSegments
    }

    /// Explicit camelCase wire keys (no snake_case spellings).
    private enum CodingKeys: String, CodingKey {
        case country
        case browser
        case devices
        case source
        case campaign
        case visitorType
        case customSegments
    }
}
