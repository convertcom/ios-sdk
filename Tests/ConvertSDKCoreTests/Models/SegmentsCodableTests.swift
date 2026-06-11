// Tests/ConvertSDKCoreTests/Models/SegmentsCodableTests.swift
import Foundation
import Testing
import ConvertSDKCore

@Suite("Segments Codable")
struct SegmentsCodableTests {
    /// A fully-populated value so every one of the seven wire keys appears in the
    /// encoded JSON. `customSegments` carries a two-element array per the contract.
    static func fullyPopulated() -> Segments {
        Segments(
            country: "US",
            browser: "Safari",
            devices: "iPhone",
            source: "newsletter",
            campaign: "spring",
            visitorType: "new",
            customSegments: ["a", "b"]
        )
    }

    // The seven camelCase wire keys, asserted present via one loop instead of seven
    // repeated `contains` lines (keeps new-duplicated-lines density under the SonarQube
    // gate). Explicit `[String]` element type keeps type-checking cheap.
    static let wireKeys: [String] = [
        "country", "browser", "devices", "source", "campaign", "visitorType", "customSegments"
    ]

    /// snake_case spellings that the camelCase wire contract forbids.
    static let forbiddenSnakeKeys: [String] = ["visitor_type", "custom_segments"]

    @Test("Segments encodes all seven camelCase wire keys")
    func encodesAllWireKeys() {
        guard let json = CodableTestHelpers.encodeJSONString(Self.fullyPopulated()) else {
            Issue.record("Segments failed to encode to a JSON string")
            return
        }
        for key in Self.wireKeys {
            #expect(json.contains("\"\(key)\""), "missing wire key \"\(key)\" in \(json)")
        }
    }

    @Test("Segments never emits snake_case keys")
    func neverSnakeCase() {
        guard let json = CodableTestHelpers.encodeJSONString(Self.fullyPopulated()) else {
            Issue.record("Segments failed to encode to a JSON string")
            return
        }
        for snake in Self.forbiddenSnakeKeys {
            #expect(!json.contains("\"\(snake)\""), "found forbidden snake_case key \"\(snake)\"")
        }
    }

    @Test("Segments round-trips through JSON unchanged")
    func roundTrips() throws {
        let original = Self.fullyPopulated()
        let data = try CodableTestHelpers.sortedKeysEncoder.encode(original)
        let decoded = try JSONDecoder().decode(Segments.self, from: data)
        #expect(decoded.country == original.country)
        #expect(decoded.browser == original.browser)
        #expect(decoded.devices == original.devices)
        #expect(decoded.source == original.source)
        #expect(decoded.campaign == original.campaign)
        #expect(decoded.visitorType == original.visitorType)
        #expect(decoded.customSegments == ["a", "b"])
    }
}
