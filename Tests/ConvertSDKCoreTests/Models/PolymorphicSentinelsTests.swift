// Tests/ConvertSDKCoreTests/Models/PolymorphicSentinelsTests.swift
import Foundation
import Testing
@testable import ConvertSDKCore

/// Unit tests for the LCD-sentinel decode layer (`PolymorphicSentinels.swift`).
///
/// These exercise the three wire invariants of the R5 / FR60 / AR16 contract using
/// constructed in-memory JSON (fixtures are a separate task):
///   1. discriminator-absent payload -> `.sentinel`, never throws;
///   2. unknown-discriminator value -> `.sentinel`, never throws;
///   3. sentinel re-serialises to the original payload (round-trip fidelity).
///
/// Anchor schema: `NumericOutlier`. It is the one config-reachable `oneOf` whose KNOWN
/// arm actually decodes from a minimal payload (its `detection_type` discriminator value
/// doubles as the `NumericOutlierBase.detection_type` enum value), so it can prove BOTH
/// the `.known` and the `.sentinel` arms. `ConfigGoal` is additionally used for the
/// LCD/round-trip cases because the CDN's stripped payload for goals is exactly the
/// discriminator-absent shape the SDK must survive in production.
@Suite("PolymorphicSentinels")
struct PolymorphicSentinelsTests {
    /// Canonicalises arbitrary JSON text to sorted-key form so two payloads can be
    /// compared independently of source key order. The sentinel round-trip guarantee is
    /// canonical-equivalence (semantic + sorted-key-stable), proven by running both the
    /// original bytes and the re-encoded sentinel through this same transform.
    static func canonical(_ json: String) throws -> Data {
        let object = try JSONSerialization.jsonObject(
            with: Data(json.utf8),
            options: [.fragmentsAllowed]
        )
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .fragmentsAllowed]
        )
    }

    static func canonical(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .fragmentsAllowed]
        )
    }

    static func decodeGoal(_ json: String) throws -> SentinelWrapped<Components.Schemas.ConfigGoal> {
        try JSONDecoder().decode(
            SentinelWrapped<Components.Schemas.ConfigGoal>.self,
            from: Data(json.utf8)
        )
    }

    static func decodeOutlier(_ json: String) throws -> SentinelWrapped<Components.Schemas.NumericOutlier> {
        try JSONDecoder().decode(
            SentinelWrapped<Components.Schemas.NumericOutlier>.self,
            from: Data(json.utf8)
        )
    }

    @Test("known variant decodes to .known")
    func knownDecodesToKnown() throws {
        let wrapped = try Self.decodeOutlier(#"{"detection_type":"none"}"#)
        guard case .known = wrapped else {
            Issue.record("expected .known for a valid NumericOutlier, got \(wrapped)")
            return
        }
    }

    @Test("discriminator-absent decodes to .sentinel without throwing")
    func absentDiscriminatorDecodesToSentinel() throws {
        let wrapped = try Self.decodeGoal(#"{"name":"My goal","key":"g1"}"#)
        guard case .sentinel = wrapped else {
            Issue.record("expected .sentinel for a discriminator-absent payload, got \(wrapped)")
            return
        }
    }

    @Test("unknown discriminator decodes to .sentinel")
    func unknownDiscriminatorDecodesToSentinel() throws {
        let wrapped = try Self.decodeGoal(#"{"type":"some_future_value","key":"g1"}"#)
        guard case .sentinel = wrapped else {
            Issue.record("expected .sentinel for an unknown discriminator, got \(wrapped)")
            return
        }
    }

    @Test("unknown discriminator on a different schema also sentinels")
    func unknownDiscriminatorOutlierSentinels() throws {
        let wrapped = try Self.decodeOutlier(#"{"detection_type":"future_kind","min":5}"#)
        guard case .sentinel = wrapped else {
            Issue.record("expected .sentinel for an unknown NumericOutlier discriminator, got \(wrapped)")
            return
        }
    }

    @Test("sentinel round-trips with canonical fidelity")
    func sentinelRoundTripsCanonically() throws {
        // A non-trivial LCD payload: nested object, array, number, bool, null, multiple keys.
        let original = #"""
        {"name":"My goal","key":"g1","threshold":95,"enabled":true,"note":null,\
        "nested":{"b":2,"a":1},"tags":["x","y"]}
        """#.replacingOccurrences(of: "\\\n", with: "")
        let wrapped = try Self.decodeGoal(original)
        guard case .sentinel = wrapped else {
            Issue.record("expected .sentinel for the LCD payload, got \(wrapped)")
            return
        }
        let reEncoded = try JSONEncoder().encode(wrapped)
        #expect(
            try Self.canonical(reEncoded) == Self.canonical(original),
            "sentinel re-encode is not canonical-equivalent to the original payload"
        )
    }

    @Test("sentinel preserves scalar number and bool values exactly")
    func sentinelPreservesScalars() throws {
        let original = #"{"min":5,"max":95.5,"flag":false,"nothing":null}"#
        let wrapped = try Self.decodeOutlier(original)
        guard case .sentinel = wrapped else {
            Issue.record("expected .sentinel, got \(wrapped)")
            return
        }
        let reEncoded = try JSONEncoder().encode(wrapped)
        #expect(try Self.canonical(reEncoded) == Self.canonical(original))
    }
}
