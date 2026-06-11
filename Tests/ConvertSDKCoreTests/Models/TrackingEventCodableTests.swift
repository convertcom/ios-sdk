// Tests/ConvertSDKCoreTests/Models/TrackingEventCodableTests.swift
import Foundation
import Testing
import ConvertSDKCore

/// FR68 precursor — locks the on-the-wire shape of the tracking payload.
///
/// CONTRACT under test (the implementer MUST satisfy these to make the suite pass):
/// - `TrackingEvent(accountId:projectId:visitors:)` hardcodes `enrichData = false`
///   and `source = "ios-sdk"` (neither is a settable init parameter).
/// - `TrackingEventEntry` exposes two static factories so callers build entries
///   without knowing the internal `TrackingEventData` representation:
///     `TrackingEventEntry.bucketing(_ data: BucketingEventData) -> TrackingEventEntry`
///     `TrackingEventEntry.conversion(_ data: ConversionEventData) -> TrackingEventEntry`
/// - `BucketingEventData(experienceId:variationId:)` and
///   `ConversionEventData(goalId:goalData:bucketingData:)` are memberwise inits.
/// - Entry wire shape: `"eventType":"bucketing"`/`"conversion"` with a FLAT `data`
///   object — NEVER the legacy `viewExp` / `hitGoal` / `tr` event names.
@Suite("TrackingEvent Codable")
struct TrackingEventCodableTests {
    /// Builds a single-visitor event whose lone entry is produced by `makeEntry`, so the
    /// bucketing and conversion cases share construction instead of repeating the
    /// `TrackingEvent` -> `Visitor` assembly verbatim across both tests.
    static func event(visitorId: String, entry: TrackingEventEntry) -> TrackingEvent {
        TrackingEvent(
            accountId: "acc1",
            projectId: "proj1",
            visitors: [Visitor(visitorId: visitorId, segments: [:], events: [entry])]
        )
    }

    @Test("bucketing event encodes the camelCase wire shape with hardcoded envelope")
    func bucketingWireShape() {
        let entry = TrackingEventEntry.bucketing(
            BucketingEventData(experienceId: "exp1", variationId: "var1")
        )
        guard let json = CodableTestHelpers.encodeJSONString(Self.event(visitorId: "vis1", entry: entry)) else {
            Issue.record("bucketing TrackingEvent failed to encode to a JSON string")
            return
        }
        #expect(json.contains("\"eventType\":\"bucketing\""))
        #expect(json.contains("\"enrichData\":false"))
        #expect(json.contains("\"source\":\"ios-sdk\""))
        #expect(json.contains("\"experienceId\":\"exp1\""))
        #expect(json.contains("\"variationId\":\"var1\""))
        // Legacy/wrong event names must never leak onto the wire.
        #expect(!json.contains("viewExp"))
        #expect(!json.contains("hitGoal"))
        #expect(!json.contains("\"tr\""))
    }

    @Test("conversion event encodes eventType and goalId")
    func conversionWireShape() {
        let entry = TrackingEventEntry.conversion(
            ConversionEventData(goalId: "goal1", goalData: nil, bucketingData: ["exp1": "var1"])
        )
        guard let json = CodableTestHelpers.encodeJSONString(Self.event(visitorId: "vis1", entry: entry)) else {
            Issue.record("conversion TrackingEvent failed to encode to a JSON string")
            return
        }
        #expect(json.contains("\"eventType\":\"conversion\""))
        #expect(json.contains("\"goalId\":\"goal1\""))
    }
}
