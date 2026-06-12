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

    /// Encodes `value` and parses it back into a `[String: Any]` tree via `JSONSerialization`,
    /// so the conversion-shape tests can inspect actual JSON structure (array vs object, key
    /// presence) instead of brittle substring matching. Records an `Issue` and returns `nil`
    /// on any failure rather than force-unwrapping (SwiftLint force-unwrap rule). Lives here so
    /// the two structural tests below share one decode block rather than copy-pasting it.
    static func encodedObject(_ value: some Encodable) -> [String: Any]? {
        guard let data = try? CodableTestHelpers.sortedKeysEncoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("value failed to encode to a JSON object")
            return nil
        }
        return object
    }

    /// Drills into the flat `data` payload of the first event of the first visitor.
    static func firstEventData(of event: TrackingEvent) -> [String: Any]? {
        let visitor = (encodedObject(event)?["visitors"] as? [[String: Any]])?.first
        let entry = (visitor?["events"] as? [[String: Any]])?.first
        return entry?["data"] as? [String: Any]
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

    /// Decode-direction invariant (AOD-1 / APB5): `enrichData` is always `false` and `source`
    /// is always `"ios-sdk"`, even when a persisted/crafted queue file claims otherwise. The
    /// `EventQueueStore.load()` path (Story 5.x) decodes events, so the synthesized decoder
    /// must NOT let the wire override these two hardcoded fields.
    @Test("decode ignores wire enrichData and source, keeping the hardcoded invariants")
    func decodeIgnoresWireEnrichDataAndSource() throws {
        let malicious = """
        {"accountId":"acc1","projectId":"proj1","enrichData":true,"source":"android-sdk",\
        "visitors":[{"visitorId":"vis1","segments":{},"events":[]}]}
        """
        guard let data = malicious.data(using: .utf8) else {
            Issue.record("failed to build malicious JSON payload")
            return
        }
        let decoded = try JSONDecoder().decode(TrackingEvent.self, from: data)
        #expect(decoded.accountId == "acc1")
        #expect(decoded.projectId == "proj1")
        #expect(decoded.enrichData == false)
        #expect(decoded.source == "ios-sdk")
    }

    /// AC5/AC8 — a conversion event carrying NON-nil `goalData` encodes `goalData` as a JSON
    /// ARRAY of `{key, value}` objects (the array-of-pairs wire form, NOT a flat
    /// `{"amount":9.99}` map), alongside the `bucketingData` map. The shape is inspected through
    /// `JSONSerialization` (array element lookup) rather than substring matching, because the
    /// array structure itself is the contract under test.
    @Test("conversion event encodes non-nil goalData as an array of {key,value} objects")
    func conversionGoalDataArrayShape() {
        let entry = TrackingEventEntry.conversion(
            ConversionEventData(
                goalId: "goal1",
                goalData: [GoalDataEntry(key: .amount, value: .double(9.99))],
                bucketingData: ["exp-1": "var-a"]
            )
        )
        guard let data = Self.firstEventData(of: Self.event(visitorId: "vis1", entry: entry)) else {
            Issue.record("conversion event data object missing")
            return
        }
        let goalData = data["goalData"] as? [[String: Any]]
        #expect(goalData?.count == 1)
        let amount = goalData?.first { $0["key"] as? String == "amount" }
        #expect(amount?["value"] as? Double == 9.99)
        #expect(data["bucketingData"] as? [String: String] == ["exp-1": "var-a"])
    }

    /// AC11 — a conversion payload with `goalData == nil` and `bucketingData == nil` OMITS both
    /// keys entirely (synthesized `encodeIfPresent`): the encoded object must contain NEITHER
    /// key, and certainly not an explicit `null`. Encodes the `ConversionEventData` directly and
    /// asserts key absence via the parsed `[String: Any]`.
    @Test("nil goalData and bucketingData are omitted, not encoded as null")
    func conversionOmitsNilOptionals() {
        guard let object = Self.encodedObject(ConversionEventData(goalId: "g-1")) else {
            Issue.record("ConversionEventData failed to encode to a JSON object")
            return
        }
        #expect(object["goalId"] as? String == "g-1")
        #expect(object["goalData"] == nil)
        #expect(object["bucketingData"] == nil)
    }
}
