// Tests/ConvertSwiftSDKCoreTests/Models/ConfigDecodeTests.swift
import Foundation
import Testing
@testable import ConvertSwiftSDKCore

/// LCD-sentinel decode validated against REAL Convert CDN captures (Story 1.4, Task 5).
///
/// Where `PolymorphicSentinelsTests` exercises the sentinel contract with constructed
/// in-memory JSON, THIS suite proves the same contract against bytes the live CDN actually
/// emitted, committed under `Tests/ConvertSwiftSDKCoreTests/Fixtures/`:
///   - `cdn-config-baseline.json`        — a full `GET .../config/10035569/10034190` capture
///     (FS-Test-Proj staging, fully configured, captured 2026-06-11).
///   - `cdn-config-ga-settings-lcd.json` — the verbatim
///     `.project.settings.integrations.google_analytics` fragment from that baseline, which
///     the CDN strips to the discriminator-ABSENT (`{"enabled":false}`) "LCD" shape when GA
///     is disabled. This is the genuine android-lcd-discriminator-strip case (AC6 / FR60).
///
/// Decoder: the SDK consumes config with a plain `Foundation.JSONDecoder` and NO
/// `keyDecodingStrategy` — the generated config types carry literal snake_case wire keys
/// (`detection_type`, `account_id`, `google_analytics`), so `.convertFromSnakeCase` is
/// forbidden (AR13) and would in fact break decoding. `runtimeDecoder` below is exactly that
/// decoder.
@Suite("ConfigDecode")
struct ConfigDecodeTests {
    // MARK: - Shared helpers (DRY: the decode+assert chain and fixture/canonical transforms
    // live in ONE place so no test body repeats a ≥10-line block — SonarQube
    // `new_duplicated_lines_density` guard).

    /// The decoder the SDK uses for CDN config: a plain `JSONDecoder`, no key strategy
    /// (AR13 — literal snake_case keys, never `.convertFromSnakeCase`).
    static let runtimeDecoder = JSONDecoder()

    /// Loads a fixture from the bundled `Fixtures/` resource directory (wired via
    /// `resources: [.copy("Fixtures")]` on the `ConvertSwiftSDKCoreTests` target in Package.swift,
    /// so `Bundle.module` resolves it). Fails the test cleanly via `#require` rather than
    /// force-unwrapping if the resource is missing.
    static func loadFixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "fixture '\(name).json' not found in the test bundle's Fixtures/ directory"
        )
        return try Data(contentsOf: url)
    }

    /// Decodes `data` as `SentinelWrapped<Known>` with the runtime decoder and asserts it
    /// landed on the `.sentinel` arm without throwing. Generic over `Known` so the headline
    /// real-fixture test and the constructed forward-compat test reuse one decode+match chain.
    @discardableResult
    static func assertSentinel<Known>(
        _ data: Data,
        as _: Known.Type,
        _ message: @autoclosure () -> String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> JSONValue? where Known: Codable & Sendable & Hashable {
        let wrapped = try runtimeDecoder.decode(SentinelWrapped<Known>.self, from: data)
        guard case let .sentinel(payload) = wrapped else {
            Issue.record("expected .sentinel — \(message())", sourceLocation: sourceLocation)
            return nil
        }
        return payload
    }

    /// Decodes `data` as `SentinelWrapped<Known>` and asserts it landed on the `.known` arm,
    /// proving the known path works end-to-end. Mirror of `assertSentinel` for the `.known`
    /// case so the two-arm coverage shares no copy-pasted decode block.
    static func assertKnown<Known>(
        _ data: Data,
        as _: Known.Type,
        _ message: @autoclosure () -> String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws where Known: Codable & Sendable & Hashable {
        let wrapped = try runtimeDecoder.decode(SentinelWrapped<Known>.self, from: data)
        guard case .known = wrapped else {
            Issue.record("expected .known — \(message())", sourceLocation: sourceLocation)
            return
        }
    }

    // MARK: - Real CDN LCD-strip (headline: AC6 bullet 2 / FR60)

    /// The REAL CDN LCD strip for disabled GA — `{"enabled":false}`, discriminator `type`
    /// ABSENT — must decode to `.sentinel` (never throw) through the GA_Settings wrapper.
    /// This is the production shape the android-lcd-discriminator-strip preemption targets,
    /// proven here against the verbatim live capture (not a hand-stripped payload).
    @Test("real LCD-stripped GA decodes to .sentinel")
    func testRealLCDStrippedGADecodesToSentinel() throws {
        let data = try Self.loadFixture("cdn-config-ga-settings-lcd")
        try Self.assertSentinel(
            data,
            as: Components.Schemas.GA_Settings.self,
            "the real CDN GA-disabled LCD fragment must sentinel, not throw"
        )
    }

    /// The sentinel for the real GA LCD fragment re-encodes with full content fidelity:
    /// re-encoding the captured payload and canonicalising both sides yields byte-equal
    /// sorted-key JSON (the round-trip guarantee `PolymorphicSentinels.swift` documents —
    /// canonical-equivalence, zero data loss, NOT literal byte-identity).
    @Test("real LCD-stripped GA round-trips with canonical fidelity")
    func testRealLCDStrippedGARoundTripsWithFidelity() throws {
        let data = try Self.loadFixture("cdn-config-ga-settings-lcd")
        let wrapped = try Self.runtimeDecoder.decode(
            SentinelWrapped<Components.Schemas.GA_Settings>.self,
            from: data
        )
        guard case .sentinel = wrapped else {
            Issue.record("expected .sentinel for the real GA LCD fragment, got \(wrapped)")
            return
        }
        let reEncoded = try JSONEncoder().encode(wrapped)
        #expect(
            try CodableTestHelpers.canonical(reEncoded) == CodableTestHelpers.canonical(data),
            "sentinel re-encode of the real GA LCD fragment is not canonical-equivalent to the capture"
        )
    }

    // MARK: - Real baseline well-formedness (NOT a full-decode claim)

    /// The real full-config baseline is committed and well-formed.
    ///
    /// This asserts the capture parses as JSON and carries its key real identifiers, WITHOUT
    /// claiming it decodes through `Components.Schemas.ConfigResponseData` — because it does
    /// NOT, by four independent spec/backend/generator drifts the conductor measured, plus a
    /// structural gap:
    ///   1. `project.utc_offset` is the String `"0"`, but generated `UTC_Offset = Int`
    ///      (spec says `integer`; backend sends a string) — SPEC/BACKEND DRIFT.
    ///   2. `project.settings.integrations.google_analytics` is the LCD `{"enabled":false}`
    ///      (GA_Settings discriminator `type` stripped) — needs the SENTINEL.
    ///   3. `goals[].type` is a String (e.g. "advanced"), but the generated `ConfigGoal`'s
    ///      inherited base reads `type` as `[GoalTypes]` (array) — GENERATOR SCHEMA COLLISION
    ///      (the discriminator name collides with an inherited array property of the same
    ///      wire name).
    ///   4. `experiences[].type` is `"a/b_fullstack"`, a case the generated `ExperienceTypes`
    ///      enum carries only once the serving-spec regen syncs the fullstack values; while it is
    ///      absent a raw element decode throws `dataCorrupted` — SPEC ENUM SYNC LAG.
    /// Structural gap: `ConfigResponseData.goals` is `[Components.Schemas.ConfigGoal]?` — the
    /// RAW generated element type, NOT `[ConfigGoalOrSentinel]`. The sentinel wrappers are not
    /// wired into the generated config tree, so even setting drifts 1/3/4 aside, decoding the
    /// full baseline through `ConfigResponseData` throws. (Known architectural finding under
    /// escalation; out of scope for this test, which only proves the capture is real and
    /// well-formed.)
    @Test("baseline fixture loads and is well-formed")
    func testBaselineFixtureLoadsAndIsWellFormed() throws {
        let data = try Self.loadFixture("cdn-config-baseline")
        #expect(!data.isEmpty, "baseline capture is empty")

        let root = try JSONSerialization.jsonObject(with: data)
        let object = try #require(root as? [String: Any], "baseline root is not a JSON object")

        #expect(object["account_id"] as? String == "10035569", "baseline account_id mismatch")

        let project = try #require(object["project"] as? [String: Any], "baseline has no project object")
        #expect(project["id"] as? String == "10034190", "baseline project.id mismatch")

        #expect(object["goals"] is [Any], "baseline goals is not an array")
        #expect(object["experiences"] is [Any], "baseline experiences is not an array")
    }

    // MARK: - Forward-compat (constructed) + known-arm proof

    /// An UNRECOGNISED discriminator value (a future backend variant this SDK build does not
    /// know) decodes to `.sentinel`, never throws — the forward-compatibility half of the
    /// contract. Constructed payload (legitimate: no live capture of a not-yet-existing
    /// variant can exist), exercised through `NumericOutlier` whose `detection_type`
    /// discriminator makes the unknown-value path unambiguous.
    @Test("unknown discriminator decodes to .sentinel")
    func testUnknownDiscriminatorDecodesToSentinel() throws {
        let data = Data(#"{"detection_type":"future_kind","min":5}"#.utf8)
        try Self.assertSentinel(
            data,
            as: Components.Schemas.NumericOutlier.self,
            "an unrecognised discriminator value must sentinel for forward-compat"
        )
    }

    /// A valid, recognised payload decodes to `.known`, proving the known arm works
    /// end-to-end (the wrapper is not a blanket sentinel that swallows everything).
    /// `NumericOutlier` with `{"detection_type":"none"}` is the minimal payload whose known
    /// variant decodes (its discriminator value doubles as the base enum value).
    @Test("known variant decodes to .known")
    func testKnownVariantDecodesToKnown() throws {
        let data = Data(#"{"detection_type":"none"}"#.utf8)
        try Self.assertKnown(
            data,
            as: Components.Schemas.NumericOutlier.self,
            "a recognised NumericOutlier must decode to .known"
        )
    }
}
