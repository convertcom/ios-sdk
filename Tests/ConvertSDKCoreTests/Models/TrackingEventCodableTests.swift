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

    /// The encoded `visitors` array of `event` as `[String: Any]` dicts, or `nil` on a shape
    /// miss. Single owner of the `encodedObject(...)["visitors"]` cast so the multi-field and
    /// multi-visitor envelope tests below share it rather than re-inlining the same drill (the
    /// SonarQube CPD gate is token-based — the duplicated cast block, not the names, is what trips
    /// it). Records an `Issue` and returns `nil` rather than force-unwrapping.
    static func visitorsArray(of event: TrackingEvent) -> [[String: Any]]? {
        guard let visitors = encodedObject(event)?["visitors"] as? [[String: Any]] else {
            Issue.record("encoded event is missing a visitors array")
            return nil
        }
        return visitors
    }

    /// The `eventType` strings of one encoded visitor dict's `events`, in wire order — the field
    /// the envelope tests assert per visitor. Shared accessor so neither test re-inlines the
    /// `events` → `eventType` map.
    static func eventTypes(of visitor: [String: Any]) -> [String] {
        let events = visitor["events"] as? [[String: Any]] ?? []
        return events.compactMap { $0["eventType"] as? String }
    }

    /// A multi-entry single visitor (segments `[:]`) carrying every entry in `entries`, so the
    /// AC5 multi-field envelope test builds its subject without re-spelling the
    /// `TrackingEvent` → `Visitor` assembly that `event(visitorId:entry:)` only does for ONE entry.
    static func event(visitorId: String, entries: [TrackingEventEntry]) -> TrackingEvent {
        TrackingEvent(
            accountId: "acc1",
            projectId: "proj1",
            visitors: [Visitor(visitorId: visitorId, segments: [:], events: entries)]
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

    /// AC5 full canonical envelope — a single visitor (segments `[:]`) holding BOTH a bucketing
    /// and a conversion entry must encode the complete multi-field shape: the hardcoded top-level
    /// envelope (`accountId`/`projectId`/`enrichData:false`/`source:"ios-sdk"`), the visitor with
    /// `visitorId`/`segments:{}`/`events:[…]`, and both entries with the correct `eventType` tag and
    /// a flat `data` object. Inspected field-by-field through the parsed `[String: Any]` tree (the
    /// shared `encodedObject`/`visitorsArray` helpers), since the envelope STRUCTURE — not a
    /// substring — is the contract under test. This is the wire shape the `EventQueue` (Story 5.1)
    /// assembles a drained batch into.
    @Test("a single visitor with a bucketing and a conversion entry encodes the full AC5 envelope")
    func fullEnvelopeEncodesCanonicalShape() {
        let event = Self.event(
            visitorId: "vis1",
            entries: [
                .bucketing(BucketingEventData(experienceId: "exp1", variationId: "var1")),
                .conversion(ConversionEventData(goalId: "goal1"))
            ]
        )
        guard let object = Self.encodedObject(event), let visitor = Self.visitorsArray(of: event)?.first else {
            return  // encodedObject / visitorsArray already recorded the Issue on failure.
        }
        // Top-level hardcoded envelope.
        #expect(object["accountId"] as? String == "acc1")
        #expect(object["projectId"] as? String == "proj1")
        #expect(object["enrichData"] as? Bool == false)
        #expect(object["source"] as? String == "ios-sdk")
        // The visitor: id, the canonical empty segments map, and BOTH entries in order.
        #expect(visitor["visitorId"] as? String == "vis1")
        #expect((visitor["segments"] as? [String: Any])?.isEmpty == true)
        #expect(Self.eventTypes(of: visitor) == ["bucketing", "conversion"])
        // The flat data of each entry (no nesting one level deeper).
        let events = visitor["events"] as? [[String: Any]]
        #expect((events?.first?["data"] as? [String: Any])?["experienceId"] as? String == "exp1")
        #expect((events?.last?["data"] as? [String: Any])?["goalId"] as? String == "goal1")
    }

    /// AC5 grouping wire proof — a two-visitor `TrackingEvent` encodes `visitors` as a 2-element
    /// array preserving CONSTRUCTION order with each visitor's own events, the on-the-wire shape
    /// the `EventQueue`'s per-visitor grouping (FR43) produces. Reuses the shared `visitorsArray` /
    /// `eventTypes` accessors so it adds no duplicated decode block (3% CPD gate).
    @Test("a two-visitor event encodes visitors as an ordered 2-element array with per-visitor events")
    func multiVisitorEncodesOrderedArray() {
        let event = TrackingEvent(
            accountId: "acc1",
            projectId: "proj1",
            visitors: [
                Visitor(
                    visitorId: "v1",
                    segments: [:],
                    events: [.bucketing(BucketingEventData(experienceId: "exp1", variationId: "var1"))]
                ),
                Visitor(
                    visitorId: "v2",
                    segments: [:],
                    events: [.conversion(ConversionEventData(goalId: "goal1"))]
                )
            ]
        )
        guard let visitors = Self.visitorsArray(of: event) else { return }
        #expect(visitors.count == 2)
        // Order preserved: v1 (bucketing) then v2 (conversion).
        #expect(visitors.first?["visitorId"] as? String == "v1")
        #expect(Self.eventTypes(of: visitors[0]) == ["bucketing"])
        #expect(visitors.last?["visitorId"] as? String == "v2")
        #expect(Self.eventTypes(of: visitors[1]) == ["conversion"])
    }

    // AC2 (FR68) — one parameterized body proves `eventType` is EXACTLY the canonical wire
    // string for BOTH kinds, replacing the two separate substring checks in `bucketingWireShape`
    // / `conversionWireShape` with a single exact-equality matrix (AC7/Task 2.2 wants the
    // eventType check parameterized to avoid copy-paste). Element type is spelled out so the
    // type-checker stays off the "expression too complex" path the untyped tuple array triggers;
    // `TrackingEventEntry` is `Sendable`, so it is a legal `@Test` argument.
    static let eventTypeCases: [(TrackingEventEntry, String)] = [
        (.bucketing(BucketingEventData(experienceId: "exp1", variationId: "var1")), "bucketing"),
        (.conversion(ConversionEventData(goalId: "goal1")), "conversion")
    ]

    @Test("eventType is exactly the canonical wire string", arguments: eventTypeCases)
    func eventTypeIsExactWireString(entry: TrackingEventEntry, expectedType: String) {
        guard let visitor = Self.visitorsArray(of: Self.event(visitorId: "vis1", entry: entry))?.first else {
            return  // visitorsArray already recorded the Issue on a shape miss.
        }
        #expect(Self.eventTypes(of: visitor) == [expectedType])
    }

    /// AC2 (FR68) no-extra-keys — a `BucketingEvent`'s `data` key-set is EXACTLY
    /// `{experienceId, variationId}`. Stronger than `bucketingWireShape`, which only proves the
    /// two keys are PRESENT (a stray extra key would slip past a substring check). Reuses
    /// `firstEventData` so it adds no new decode block (3% CPD gate).
    @Test("bucketing data carries exactly experienceId and variationId, no extra keys")
    func bucketingDataKeySetIsExact() {
        let entry = TrackingEventEntry.bucketing(
            BucketingEventData(experienceId: "exp1", variationId: "var1")
        )
        guard let data = Self.firstEventData(of: Self.event(visitorId: "vis1", entry: entry)) else {
            Issue.record("bucketing event data object missing")
            return
        }
        #expect(Set(data.keys) == ["experienceId", "variationId"])
    }

    /// AC2 (FR68) bounded key-set — a `ConversionEvent`'s `data` keys are a SUBSET of
    /// `{goalId, goalData, bucketingData}` (no compact/extra keys), with `goalData` and
    /// `bucketingData` present when supplied. Complements `conversionGoalDataArrayShape` (which
    /// asserts the VALUES) by bounding the key-set itself. Reuses `firstEventData`.
    @Test("conversion data keys are a subset of {goalId, goalData, bucketingData}")
    func conversionDataKeySetIsBounded() {
        let entry = TrackingEventEntry.conversion(
            ConversionEventData(
                goalId: "goal1",
                goalData: [GoalDataEntry(key: .amount, value: .double(9.99))],
                bucketingData: ["exp1": "var1"]
            )
        )
        guard let data = Self.firstEventData(of: Self.event(visitorId: "vis1", entry: entry)) else {
            Issue.record("conversion event data object missing")
            return
        }
        #expect(Set(data.keys).isSubset(of: ["goalId", "goalData", "bucketingData"]))
        #expect(data["goalData"] != nil)
        #expect(data["bucketingData"] != nil)
    }

    /// FR43 "no compact payload variant may appear anywhere" — the encoded full envelope must
    /// NOT contain any abbreviated key spelling for the four camelCase fields it carries
    /// (`experienceId`/`variationId`/`goalId`/`eventType`). Complements the
    /// `viewExp`/`hitGoal`/`tr` legacy-name negatives in `bucketingWireShape` with the
    /// compact-key-name negatives. Reuses the shared `encodeJSONString` helper.
    @Test("encoded envelope contains no compact/abbreviated key names")
    func envelopeHasNoAbbreviatedKeys() {
        let event = Self.event(
            visitorId: "vis1",
            entries: [
                .bucketing(BucketingEventData(experienceId: "exp1", variationId: "var1")),
                .conversion(ConversionEventData(goalId: "goal1"))
            ]
        )
        guard let json = CodableTestHelpers.encodeJSONString(event) else {
            Issue.record("full-envelope TrackingEvent failed to encode to a JSON string")
            return
        }
        for abbreviated in ["\"eId\"", "\"vId\"", "\"gId\"", "\"evt\""] {
            #expect(!json.contains(abbreviated), "compact key \(abbreviated) leaked onto the wire")
        }
    }
}
