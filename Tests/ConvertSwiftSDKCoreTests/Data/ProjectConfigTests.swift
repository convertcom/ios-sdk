// Tests/ConvertSwiftSDKCoreTests/Data/ProjectConfigTests.swift
import Foundation
import Testing
@testable import ConvertSwiftSDKCore

/// RED-phase contract for `ProjectConfig` — the hand-authored DEGRADING decode root for
/// CDN config (Epic 2 / Story 3, the central decode task).
///
/// `ProjectConfig` does NOT exist yet, so this suite is EXPECTED to fail to COMPILE (RED).
/// The GREEN-phase implementer creates `struct ProjectConfig: Decodable, Sendable` in
/// `Sources/ConvertSwiftSDKCore/...`; this suite both proves the contract and DEFINES the wrapper's
/// public shape (see "PUBLIC SHAPE this suite assumes" below — the GREEN impl MUST match it).
///
/// ── Why a degrading root is needed (NOT the raw generated `ConfigResponseData`) ──────────
/// The real CDN baseline does NOT decode through the raw generated
/// `Components.Schemas.ConfigResponseData`. Four measured drifts + one structural gap make a
/// straight `decode` throw (documented at length in `Models/ConfigDecodeTests.swift`, lines
/// ~117-157). The relevant four for THIS suite, verified against the generated types:
///   - D1 `project.utc_offset` is the wire String `"0"`, but generated
///     `ConfigProject.utc_offset` is `UTC_Offset = Swift.Int` (synthesized Codable) → a raw
///     decode throws `DecodingError.typeMismatch`. Degrading disposition: `utcOffset == nil`.
///   - D2 `project.settings.integrations.google_analytics` is the LCD `{"enabled":false}`
///     (the `GA_Settings` oneOf discriminator `type` is stripped) → a raw `GA_Settings` decode
///     throws `keyNotFound`. Degrading disposition: the `.sentinel` arm of `GASettingsOrSentinel`.
///   - D3 `goals[].type` is the wire String `"advanced"`; the generated `ConfigGoal` oneOf
///     reads `type` as a String discriminator (→ `.advanced`) but its composed
///     `ConfigGoalBase.type` is `[GoalTypes]` (array) → the nested base decode throws
///     `typeMismatch` on the String. Degrading disposition: `ConfigGoalOrSentinel` `.sentinel`
///     (never throws), all goals retained by count.
///   - D4 `experiences[].type` is the wire String `"a/b_fullstack"`, which is NOT a case of
///     the generated `ExperienceTypes` enum (it lacks the fullstack values) → a raw
///     `ConfigExperience` decode throws `DecodingError.dataCorrupted`. Degrading disposition:
///     the experience survives and its `type` is degraded/absent (`type == nil`).
///
/// `ProjectConfig.init(from:)` therefore decodes the `ConfigResponseData` root field-by-field
/// and degrades each non-decodable sub-tree to nil / `.sentinel` instead of throwing, reusing
/// the sanctioned `SentinelWrapped` layer (`PolymorphicSentinels.swift`) where a oneOf is
/// involved.
///
/// ── PUBLIC SHAPE this suite assumes (GREEN impl MUST provide exactly these) ───────────────
/// `struct ProjectConfig: Decodable, Sendable` with:
///   - `var accountId: String?`                       (wire `account_id`)
///   - `var project: ProjectConfig.Project?`          (degrading project; nil only if absent)
///   - `var goals: [ConfigGoalOrSentinel]?`           (sentinel-wrapped goals; D3)
///   - `var experiences: [ProjectConfig.Experience]?` (tolerant experiences; D4)
///   - `var audiences: [Components.Schemas.ConfigAudience]?`
///   - `var segments: [Components.Schemas.ConfigSegment]?`
///   - `var locations: [Components.Schemas.ConfigLocation]?`
///   - `var features: [Components.Schemas.ConfigFeature]?`
///
/// Nested `struct ProjectConfig.Project: Decodable, Sendable`:
///   - `var id: String?`                              (wire `id`)
///   - `var utcOffset: Int?`                          (wire `utc_offset`; nil on non-Int → D1)
///   - `var googleAnalytics: GASettingsOrSentinel?`   (wire path settings.integrations
///                                                     .google_analytics; `.sentinel` on LCD → D2)
///
/// Nested `struct ProjectConfig.Experience: Decodable, Sendable`:
///   - `var id: String?`                              (wire `id`)
///   - `var type: Components.Schemas.ExperienceTypes?`(nil when the wire value is not a known
///                                                     `ExperienceTypes` case → D4)
///
/// Decoder: a plain `Foundation.JSONDecoder`, NO `keyDecodingStrategy`. The generated config
/// types carry literal snake_case `CodingKeys` (`account_id`, `utc_offset`, `google_analytics`),
/// so `.convertFromSnakeCase` is FORBIDDEN (AR13) and would break decoding — hence the wrapper
/// and this suite map wire→property by explicit `CodingKeys`, never by a key strategy.
@Suite("ProjectConfig")
struct ProjectConfigTests {
    // MARK: - Shared helpers
    // (DRY: one decoder + one fixture loader + one decode entry point so neither test body
    // repeats a ≥10-line block — SonarQube `new_duplicated_lines_density` 3% guard. Mirrors
    // the `runtimeDecoder` / `loadFixture` pattern in `ConfigDecodeTests` rather than
    // re-deriving it inline per test.)

    /// The decoder the SDK uses for CDN config: a plain `JSONDecoder`, NO key strategy
    /// (AR13 — literal snake_case keys, never `.convertFromSnakeCase`).
    static let runtimeDecoder = JSONDecoder()

    /// Loads a fixture from the bundled `Fixtures/` resource directory (wired via
    /// `resources: [.copy("Fixtures")]` on the `ConvertSwiftSDKCoreTests` target, so `Bundle.module`
    /// resolves it). `#require`s rather than force-unwraps a missing resource.
    static func loadFixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "fixture '\(name).json' not found in the test bundle's Fixtures/ directory"
        )
        return try Data(contentsOf: url)
    }

    /// Single decode entry point: decode `data` as `ProjectConfig` with the runtime decoder.
    /// Throwing here IS the failure signal for the binding test (a degrading decode must not
    /// throw), and the same call decodes the clean payload — so both tests share ONE decode
    /// line and assert on the returned value.
    static func decode(_ data: Data) throws -> ProjectConfig {
        try runtimeDecoder.decode(ProjectConfig.self, from: data)
    }

    // MARK: - The BINDING test: real CDN baseline degrades, never throws

    /// THE headline contract. Decoding the REAL `cdn-config-baseline.json` through
    /// `ProjectConfig`:
    ///   (1) does NOT throw — a plain `try decode(...)` that throws fails the test, which IS
    ///       the non-throwing assertion;
    ///   (2) is usable for bucketing — `accountId` and `project.id` carry their real values;
    ///   (3) honours every drift disposition D1–D4 (see suite doc) against the live capture.
    @Test("real CDN baseline decodes degrade-not-throw, with D1–D4 dispositions")
    func realBaselineDegradesWithoutThrowing() throws {
        let data = try Self.loadFixture("cdn-config-baseline")

        // (1) Non-throwing degrade: if `decode` throws, this line fails the test.
        let config = try Self.decode(data)

        // (2) Usable: real identifiers survive the degrade.
        #expect(config.accountId == "10035569", "baseline account_id must survive the degrade")
        let project = try #require(config.project, "baseline must carry a decoded project")
        #expect(project.id == "10034190", "baseline project.id must survive the degrade")

        // (3) D1 — utc_offset is the String "0", not an Int → degraded to nil, NOT thrown.
        #expect(project.utcOffset == nil, "D1: non-Int utc_offset must degrade to nil")

        // (3) D2 — GA is the LCD {"enabled":false} (discriminator stripped) → the .sentinel arm.
        let gaSettings = try #require(
            project.googleAnalytics,
            "D2: GA sub-tree must be present (sentinel)"
        )
        guard case .sentinel = gaSettings else {
            Issue.record("D2: LCD-stripped GA must land on the .sentinel arm, got \(gaSettings)")
            return
        }

        // (3) D3 — goals retained by count, decoded as sentinel-or-known WITHOUT throwing on the
        // "advanced" String-vs-array collision. Fixture top-level `goals` has 3 entries.
        let goals = try #require(config.goals, "D3: goals array must be present")
        #expect(goals.count == 3, "D3: all baseline goals must be retained (3)")

        // (3) D4 — experiences retained by count; experiences[0] survived with its `type`
        // degraded/absent for the "a/b_fullstack" value. Fixture `experiences` has 4 entries.
        let experiences = try #require(config.experiences, "D4: experiences array must be present")
        #expect(experiences.count == 4, "D4: all baseline experiences must be retained (4)")
        let firstExperience = try #require(experiences.first, "D4: experiences[0] must be present")
        #expect(firstExperience.id == "100334665", "D4: experiences[0] identity must survive")
        #expect(
            firstExperience.type == nil,
            "D4: the unknown 'a/b_fullstack' experience type must degrade to nil, not throw"
        )
    }

    // MARK: - The CLEAN test: real data actually decodes (not a blanket degrade-to-nil)

    /// Proves `ProjectConfig` is NOT a blanket "everything degrades to nil" wrapper: a minimal,
    /// well-formed payload populates `accountId` and `project.id` with no unexpected
    /// degradation. Same decode entry point as the binding test (shared helper → no copy-paste).
    @Test("clean well-formed payload decodes with no unexpected degradation")
    func cleanPayloadDecodesPopulated() throws {
        let data = Data(#"{"account_id":"acc-7","project":{"id":"proj-7"}}"#.utf8)

        let config = try Self.decode(data)

        #expect(config.accountId == "acc-7", "clean account_id must populate")
        let project = try #require(config.project, "clean payload must carry a decoded project")
        #expect(project.id == "proj-7", "clean project.id must populate")
    }

    // MARK: - PC-1 shared builders (full-experience retention + audience/location lookups)
    // (DRY: the `{"account_id":…,"experiences":[…],…}` envelope and the valid-experience JSON
    // each appear ONCE here so no test body repeats a ≥10-line literal — SonarQube CPD is
    // token-based, so the shared envelope/experience literals are what keep the diff under the
    // 3% `new_duplicated_lines_density` gate. Each test passes only the array fragment it needs.)

    /// Wraps array fragments in the `ConfigResponseData` wire envelope so each PC-1 test supplies
    /// only the slice it exercises. Defaults keep the unrelated arrays empty (`[]` decodes to an
    /// empty typed array, never a degrade) so a test that cares only about experiences need not
    /// spell out audiences/locations, and vice-versa.
    static func makeConfigData(
        experiencesJSON: String = "[]",
        audiencesJSON: String = "[]",
        locationsJSON: String = "[]"
    ) -> Data {
        Data(
            """
            {"account_id":"acc","project":{"id":"p"},\
            "experiences":\(experiencesJSON),\
            "audiences":\(audiencesJSON),\
            "locations":\(locationsJSON)}
            """.utf8
        )
    }

    /// A single well-formed `ConfigExperience` JSON object carrying the FULL shape PC-1 must
    /// retain (`id`, `key`, a known `type`, and a `variations` array) — the part the stripped
    /// `ProjectConfig.Experience` drops. Shared by the valid-type and per-element-degrade tests
    /// so the variations literal is written once.
    static func validExperienceJSON(id: String, key: String) -> String {
        """
        {"id":"\(id)","key":"\(key)","type":"a/b",\
        "variations":[{"id":"var-a","key":"control","traffic_allocation":100}]}
        """
    }

    // MARK: - PC-1: fullExperience(forKey:) returns the FULL generated experience

    /// `fullExperience(forKey:)` returns the FULL generated `ConfigExperience` — with `key` and
    /// the `variations` array — not the stripped `ProjectConfig.Experience` (which carries only
    /// `id`/`type`). Proves the new raw retention exposes variations for sticky assignment.
    @Test("fullExperience returns the full generated type (with variations) for a valid experience")
    func fullExperienceReturnsFullTypeForValidExperience() throws {
        let data = Self.makeConfigData(
            experiencesJSON: "[\(Self.validExperienceJSON(id: "exp-100", key: "valid-exp"))]"
        )

        let config = try Self.decode(data)

        let full = try #require(
            config.fullExperience(forKey: "valid-exp"),
            "the valid experience must be retrievable by key from the raw retention"
        )
        #expect(full.id == "exp-100", "the full experience must carry its wire id")
        #expect(full.key == "valid-exp", "the full experience must carry its wire key")
        let variation = try #require(
            full.variations?.first,
            "the FULL type must retain variations (the stripped Experience drops them)"
        )
        #expect(variation.id == "var-a", "the retained variation must carry its wire id")
    }

    /// THE critical PC-1 test: per-element-degrade, NOT whole-array-throw. The array holds one
    /// valid experience and one drifted `a/b_fullstack` element (unknown `ExperienceTypes` →
    /// `dataCorrupted`). A naive whole-array `[ConfigExperience]` decode throws on the drifted
    /// element and loses BOTH; the contract requires each element to decode under its own `try?`,
    /// so the valid sibling SURVIVES (with variations) and only the drifted element degrades out.
    @Test("fullExperience per-element degrade keeps the valid sibling, drops the drifted one")
    func fullExperiencePerElementDegradeKeepsValidSibling() throws {
        let drifted = #"{"id":"exp-bad","key":"bad","type":"a/b_fullstack"}"#
        let data = Self.makeConfigData(
            experiencesJSON: "[\(Self.validExperienceJSON(id: "exp-good", key: "good")),\(drifted)]"
        )

        let config = try Self.decode(data)

        // The valid sibling survived per-element decode — proves NOT a whole-array throw-to-nil.
        let good = try #require(
            config.fullExperience(forKey: "good"),
            "the valid sibling must survive when a drifted element shares the array"
        )
        #expect(
            good.variations?.first?.id == "var-a",
            "the surviving sibling must retain its variations intact"
        )
        // The drifted element degraded out of the raw retention — proves per-element `try?`.
        #expect(
            config.fullExperience(forKey: "bad") == nil,
            "the drifted a/b_fullstack element must degrade out, not be retained"
        )
    }

    /// A key with no matching experience returns nil (lookup miss, not a degrade).
    @Test("fullExperience returns nil for an unknown key")
    func fullExperienceReturnsNilForUnknownKey() throws {
        let data = Self.makeConfigData(
            experiencesJSON: "[\(Self.validExperienceJSON(id: "exp-100", key: "valid-exp"))]"
        )

        let config = try Self.decode(data)

        #expect(
            config.fullExperience(forKey: "no-such") == nil,
            "an unmatched key must return nil"
        )
    }

    // MARK: - PC-1: audience(id:) / location(id:) lookups over the existing typed arrays

    /// `audience(id:)` and `location(id:)` look up by id in the already-decoded `audiences` /
    /// `locations` arrays; an unknown id returns nil. Audience/location JSON is kept minimal
    /// (`rules` is optional on both generated types, so it is omitted — only id/key are needed
    /// to decode through `ConfigAudience` / `ConfigLocation`).
    @Test("audience(id:) and location(id:) resolve by id, and miss to nil for unknown ids")
    func audienceAndLocationLookupById() throws {
        let data = Self.makeConfigData(
            audiencesJSON: #"[{"id":"aud-1","key":"k"}]"#,
            locationsJSON: #"[{"id":"loc-1","key":"k"}]"#
        )

        let config = try Self.decode(data)

        #expect(config.audience(id: "aud-1")?.id == "aud-1", "audience must resolve by id")
        #expect(config.location(id: "loc-1")?.id == "loc-1", "location must resolve by id")
        #expect(config.audience(id: "missing") == nil, "unknown audience id must miss to nil")
        #expect(config.location(id: "missing") == nil, "unknown location id must miss to nil")
    }

    // MARK: - goal(forKey:) returns the embedded ConfigGoalBase (Epic 4 / Story 2)
    //
    // RED-phase contract for the NEW `goal(forKey:)` accessor (does NOT exist yet):
    //
    //     public func goal(forKey key: String) -> Components.Schemas.ConfigGoalBase?
    //
    // The conversion-tracking path resolves a caller's goalKey → the wire goalId by looking the
    // goal up by `key` and reading the embedded base's `id`. These tests pin that lookup AND the
    // crash-safety the sentinel-degraded goal arm demands.
    //
    // ── A note on the decode reality these tests are written against (probed, not assumed) ────
    // On the wire EVERY goal carries `type` as a bare String discriminator, which makes
    // `ConfigGoalOrSentinel` land on `.sentinel` (the embedded `ConfigGoalBase._type` is
    // `[GoalTypes]`, so the String collides → `typeMismatch` → sentinel; this is drift D3). The
    // `.sentinel` payload retains every field (`id`/`key`/`type`) as `JSONValue` — VERIFIED by an
    // empirical decode probe. There is therefore NO goal that decodes to the `.known` arm from any
    // production wire shape, so `goal(forKey:)` MUST resolve the base from the retained payload; a
    // reader that only inspects `.known` arms would return nil for every real goal and silently
    // break goalKey→goalId resolution. (See the matching note in `ProjectConfigFixtures.goalJSON`.)

    /// Decodes a `ProjectConfig` from the goal fragments alone (no other arrays). One splice point
    /// so neither goal test re-inlines the `[ <goal>, … ]` envelope (SonarQube 3% gate; CPD is
    /// token-based — reuse, not renaming, holds the diff under the threshold).
    static func goalConfig(_ goals: String...) throws -> ProjectConfig {
        try ProjectConfigFixtures.goalsConfig(goalsJSON: "[" + goals.joined(separator: ",") + "]")
    }

    /// `goal(forKey:)` resolves a goal by its `key` and exposes the embedded `ConfigGoalBase` —
    /// `id` (the wire goalId the conversion path emits) and `key` — and misses to `nil` for a key
    /// no goal carries. Two goals prove the lookup discriminates by key rather than returning the
    /// first goal unconditionally.
    @Test("goal(forKey:) returns the base (id + key) for a known key, nil for an unknown one")
    func goalReturnsBaseForKnownKeyNilForUnknown() throws {
        let config = try Self.goalConfig(
            ProjectConfigFixtures.goalJSON(id: "g-1", key: "primary"),
            ProjectConfigFixtures.goalJSON(id: "g-2", key: "secondary")
        )

        let base = try #require(
            config.goal(forKey: "primary"),
            "a goal present by key must resolve to its embedded ConfigGoalBase"
        )
        #expect(base.id == "g-1", "the resolved base must carry the wire goalId")
        #expect(base.key == "primary", "the resolved base must carry the looked-up key")
        // A second key resolves independently — proves the lookup keys on `key`, not array position.
        #expect(config.goal(forKey: "secondary")?.id == "g-2", "the other goal must resolve by its key")
        #expect(config.goal(forKey: "no-such") == nil, "an unmatched goal key must miss to nil")
    }

    /// Crash-safety: `goal(forKey:)` MUST NOT crash when a sentinel-decoded goal sits in the array,
    /// must still resolve a sibling by key, and must still miss cleanly to `nil` for an absent key.
    ///
    /// BOTH goals here decode to `.sentinel`, not just the `type:"totally_unknown_type_xyz"` one: per
    /// drift D3 EVERY wire goal sentinels (the `"advanced"` discriminator collides with
    /// `ConfigGoalBase._type: [GoalTypes]` → `typeMismatch` → `SentinelWrapped` falls to `.sentinel`),
    /// so this test exercises the `.sentinel` payload path TWICE — once with a recognised-but-still-
    /// sentineled `type`, once with a genuinely unknown `type`. The `.known` arm of `goalBase(from:)`
    /// is therefore NOT exercised by any current fixture; when D3 is resolved and goals begin decoding
    /// via `.known`, add a companion test that pins `base(fromKnown:)` (reaching `.value1`).
    @Test("goal(forKey:) tolerates a sentinel-decoded goal: a sibling resolves, a miss returns nil")
    func goalLookupToleratesSentinelDegradedGoal() throws {
        let config = try Self.goalConfig(
            ProjectConfigFixtures.goalJSON(id: "g-good", key: "resolvable-goal"),
            ProjectConfigFixtures.goalJSON(id: "g-degraded", key: "degraded-goal", type: "totally_unknown_type_xyz")
        )

        // A sentineled goal still resolves by its key with another sentineled goal present in the array.
        #expect(
            config.goal(forKey: "resolvable-goal")?.id == "g-good",
            "a resolvable goal must survive a sentinel-decoded sibling in the same array"
        )
        // A key no goal carries still misses to nil — the sentinel element does not crash the scan.
        #expect(
            config.goal(forKey: "absent-key") == nil,
            "a miss must return nil even with a sentinel-degraded goal in the array, never crash"
        )
    }
}
