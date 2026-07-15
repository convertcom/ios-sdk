// Tests/ConvertSwiftSDKCoreTests/Data/ProjectConfigAudienceDegradeTests.swift
//
// RED-phase contract for IOS-1 (M1 decode-survival seam, iOS mutual-exclusion qs-03): a NEW
// audience rule leaf `bucketed_into_experience_key` is absent from the generated
// `RuleElementAudience` oneOf, so its decoder's `default:` case throws
// `DecodingError.unknownOneOfDiscriminator` (Generated/ConfigSchemas.swift:3399-3404, discriminator
// key `rule_type`, confirmed absent from `discriminator-manifest.json`'s `RuleElementAudience` entry
// alongside the sibling KNOWN case `bucketed_into_experience`).
//
// TODAY, `ProjectConfig.init(from:)` decodes `audiences` via a WHOLE-ARRAY `try?`
// (`ProjectConfig.swift:155-158`):
//
//     audiences = try? container.decodeIfPresent([Components.Schemas.ConfigAudience].self, forKey: .audiences)
//
// So a SINGLE audience carrying the new leaf makes the ENTIRE array decode throw
// `unknownOneOfDiscriminator`; the `try?` converts that to `audiences == nil`; and
// `ExperienceManager.audiencePasses` (`ExperienceManager.swift:329-341`) treats an empty/nil
// audience set as UNRESTRICTED and returns `true` — a PROJECT-WIDE fail-OPEN regression the moment
// ANY audience anywhere in the config uses the new rule type.
//
// The eventual GREEN fix (NOT this task) is a hand-authored PER-AUDIENCE degrading decode in
// `ProjectConfig.swift`, mirroring the existing `DegradingExperience` per-element loop
// (`ProjectConfig.swift:136-154`, `:338-359` — the "LOOP-TERMINATION INVARIANT" comment) so a
// bad/unknown audience degrades out ALONE (siblings survive, array never nulled), and
// sentinel-captures the unknown leaf's raw JSON via the ALREADY-DEFINED-BUT-UNWIRED
// `RuleElementAudienceOrSentinel` typealias (`Generated/PolymorphicSentinels.swift:250-252` — grep
// confirms ZERO references to it anywhere in `Sources/` today) so a later task (IOS-2) can read the
// leaf's `rule_type` / `value` / `negated`.
//
// ── Scope of THIS suite ──────────────────────────────────────────────────────────────────────
// `ProjectConfig` decode ONLY. `ExperienceManager.audiencePasses`'s fail-open consequence is cited
// above for context/motivation but is NOT exercised here (out of scope for IOS-1).
//
// ── Why this suite could NOT pin the full "sentinel exposes rule_type/value/negated" contract
// against a NEW `ProjectConfig` accessor ──────────────────────────────────────────────────────
// The GREEN-phase accessor shape for reading a preserved audience's captured sentinel does not
// exist yet, and no story artifact fixes its exact shape (IOS-2/RuleAdapter is the future
// consumer — see `work/2026-07-15-ios-sdk-mutual-exclusion/workflow-state.yaml` lines 197-201).
// Referencing an invented symbol here would fail this file to COMPILE, and because
// `ConvertSwiftSDKCoreTests` is a single SPM module, that would break `swift test`/`swift build`
// for EVERY suite in the target, not just this one — the dispatch's "Verify RED" instructions
// explicitly rule out a compile-error RED. This suite therefore proves the two halves of the
// "preserved-with-sentinel" contract SEPARATELY, using ONLY symbols that exist in Sources/ today:
//   (1) `audienceWithUnknownLeafIsPreservedNotDropped` — the FAILING half: `ProjectConfig`'s own
//       `audience(id:)` must retrieve the bad audience by id (fails today — nil).
//   (2) `sentinelWrappedAudienceAlreadyPreservesUnknownLeafFidelity` — an EVIDENCE test (passes
//       today by design): proves the exact building block IOS-1's plan calls for
//       (`SentinelWrapped`/`JSONValue`, already public, already correct) round-trips the unknown
//       leaf's `rule_type`/`value`/`negated` with full fidelity when applied directly to an
//       audience — i.e., the mechanism GREEN needs is ready and correct; only the WIRING into
//       `ProjectConfig`'s own per-audience decode (test (1)) is the actual defect.
// This split is a documented ASSUMPTION/DECISION — see the sibling planning repo's decision log
// (`work/2026-07-15-ios-sdk-mutual-exclusion/decision-log.md`, "Implementation-level decisions").
import Foundation
import Testing
@testable import ConvertSwiftSDKCore

@Suite("ProjectConfig audience decode-survival (IOS-1 RED)")
struct ProjectConfigAudienceDegradeTests {
    // MARK: - Shared fixtures
    // (DRY: one envelope helper — reused from `ProjectConfigFixtures.makeConfig` — plus ONE
    // leaf-parameterized audience builder, so no test body repeats a ≥10-line JSON literal.
    // SonarQube `new_duplicated_lines_density` 3% guard; CPD is token-based, so reuse — not
    // renaming — is what keeps the diff under the threshold.)

    /// A KNOWN rule leaf (`country == "US"`) — the exact shape `ProjectConfigFixtures.audienceJSON`
    /// and `RuleAdapterTests` already prove decodes end-to-end. Used as the "everything is fine"
    /// control so a test can prove ONE sibling in the array is the sole cause of a degrade.
    static let knownLeafJSON = #"{"rule_type":"country","value":"US","matching":{"match_type":"equals"}}"#

    /// The NEW, unrecognised rule leaf under test: `bucketed_into_experience_key`, absent from the
    /// generated `RuleElementAudience` oneOf (confirmed against `ConfigSchemas.swift:3294-3398` and
    /// `discriminator-manifest.json`). `value` carries the target experience KEY (`"exp-a"`); the
    /// discriminator has NO parity with the existing KNOWN `"bucketed_into_experience"` case.
    static let unknownLeafJSON = #"{"rule_type":"bucketed_into_experience_key","value":"exp-a","negated":false}"#

    /// Builds ONE `ConfigAudience` JSON object whose `rules` graph is the fixed
    /// `OR -> AND -> OR_WHEN` envelope (verified against `RuleObjectAudience`,
    /// `ConfigSchemas.swift:3613-3667`) wrapping a single CALLER-SUPPLIED leaf fragment. Lets this
    /// suite swap in the known vs. unknown leaf without duplicating the audience envelope per call.
    static func audienceWithLeafJSON(id: String, key: String, leafJSON: String) -> String {
        """
        {"id":"\(id)","key":"\(key)","type":"transient","rules":\
        {"OR":[{"AND":[{"OR_WHEN":[\(leafJSON)]}]}]}}
        """
    }

    /// Renders a list of pre-built audience JSON object literals as a JSON array.
    static func audiencesArrayJSON(_ audiences: [String]) -> String {
        "[" + audiences.joined(separator: ",") + "]"
    }

    // MARK: - Requirement 1: fail-open regression lock (siblings survive, position-independent)

    /// THE headline regression lock. THREE audiences share the array; exactly ONE (at
    /// `badIndex`) carries the unknown leaf, the other two carry the known `country` leaf.
    /// Parameterized over every position so the contract does not depend on where in the config
    /// the bad audience happens to sit (avoids 3 near-duplicate test bodies — SonarQube 3% gate).
    ///
    /// MUST FAIL TODAY: the current whole-array `try?` (`ProjectConfig.swift:155-158`) throws on
    /// the embedded `unknownOneOfDiscriminator` and degrades `audiences` to `nil` regardless of
    /// position, so `#require(config.audiences, ...)` fails for every `badIndex`.
    @Test(
        "an unknown-leaf audience degrades out ALONE — siblings survive regardless of its position",
        arguments: [0, 1, 2]
    )
    func siblingAudiencesSurviveRegardlessOfBadPosition(badIndex: Int) throws {
        var audiences = (1...3).map { index in
            Self.audienceWithLeafJSON(id: "aud-\(index)", key: "k-\(index)", leafJSON: Self.knownLeafJSON)
        }
        audiences[badIndex] = Self.audienceWithLeafJSON(
            id: "aud-\(badIndex + 1)",
            key: "k-\(badIndex + 1)",
            leafJSON: Self.unknownLeafJSON
        )
        let config = try ProjectConfigFixtures.makeConfig(
            experiencesJSON: "[]",
            audiencesJSON: Self.audiencesArrayJSON(audiences)
        )

        let retained = try #require(
            config.audiences,
            """
            siblings must survive a single sibling's unknown discriminator at position \(badIndex), \
            not degrade the WHOLE audiences array to nil
            """
        )
        #expect(
            retained.count == 3,
            """
            all three audiences (2 known-leaf + 1 preserved-but-unknown-leaf) must be retained \
            when the bad leaf sits at position \(badIndex)
            """
        )
    }

    // MARK: - Requirement 2 (half 1 — FAILING): the bad audience itself is preserved, not dropped

    /// The audience CARRYING the unknown leaf must itself remain retrievable by id — not silently
    /// dropped from the array (a naive "keep only the array, drop the bad element" degrade — the
    /// literal `DegradingExperience` mirror — would satisfy requirement 1 alone but would still
    /// DROP `"aud-bad"`, which is insufficient per the IOS-1 plan: "degrade a bad/unknown audience
    /// ALONE" is scoped as "siblings survive", but the plan additionally requires the leaf itself be
    /// SENTINEL-CAPTURED for IOS-2, which requires PRESERVING the audience, not discarding it).
    ///
    /// MUST FAIL TODAY: `config.audience(id:)` looks up in the (today nil) `audiences` array, so
    /// this returns `nil` for `"aud-bad"` exactly as it does for every audience right now.
    @Test("the audience carrying the unknown leaf is itself preserved, not silently dropped")
    func audienceWithUnknownLeafIsPreservedNotDropped() throws {
        let good = Self.audienceWithLeafJSON(id: "aud-good", key: "good", leafJSON: Self.knownLeafJSON)
        let bad = Self.audienceWithLeafJSON(id: "aud-bad", key: "bad", leafJSON: Self.unknownLeafJSON)
        let config = try ProjectConfigFixtures.makeConfig(
            experiencesJSON: "[]",
            audiencesJSON: Self.audiencesArrayJSON([good, bad])
        )

        #expect(
            config.audience(id: "aud-bad") != nil,
            """
            the audience whose rule tree embeds an unknown rule_type discriminator must still be \
            retrievable by id, not silently dropped from the audiences array
            """
        )
    }

    // MARK: - Requirement 2 (half 2 — EVIDENCE, passes today by design): sentinel fidelity

    /// EVIDENCE test, NOT itself the `ProjectConfig` contract (see the FAILING test directly above
    /// for that half). Proves the exact mechanism the IOS-1 plan calls for — the ALREADY-PUBLIC,
    /// ALREADY-CORRECT `SentinelWrapped<Known>` generic wrapper applied to
    /// `Components.Schemas.ConfigAudience` (which already conforms `Codable & Sendable & Hashable`,
    /// so `SentinelWrapped<Components.Schemas.ConfigAudience>` compiles and works TODAY with ZERO
    /// Sources changes) — round-trips an unknown-leaf audience to its `.sentinel` arm with the
    /// leaf's `rule_type`/`value`/`negated` fully intact, structurally, inside the captured
    /// `JSONValue` payload.
    ///
    /// This is EXPECTED TO PASS TODAY: it demonstrates the building block GREEN's per-audience
    /// degrading decode must wire up (per the plan: "SENTINEL-CAPTURE the unknown leaf's raw JSON
    /// via the existing SentinelWrapped/JSONValue mechanism") is ready and correct RIGHT NOW; the
    /// defect is that `ProjectConfig.init(from:)` does not yet USE it for `audiences` (proven by the
    /// two failing tests above). Included per the dispatch's requirement 2 ask to make the intended
    /// "sentinel exposing rule_type/value/negated" shape concrete — see the file-header note on why
    /// this could not instead be asserted directly against a new `ProjectConfig` accessor without
    /// risking a target-wide compile break.
    @Test("""
        SentinelWrapped<ConfigAudience> already round-trips an unknown leaf's rule_type/value/negated \
        (infra evidence for GREEN, not the ProjectConfig contract)
        """)
    func sentinelWrappedAudienceAlreadyPreservesUnknownLeafFidelity() throws {
        let badAudienceJSON = Self.audienceWithLeafJSON(id: "aud-bad", key: "bad", leafJSON: Self.unknownLeafJSON)
        let data = Data(badAudienceJSON.utf8)

        let wrapped = try JSONDecoder().decode(
            SentinelWrapped<Components.Schemas.ConfigAudience>.self,
            from: data
        )

        guard case let .sentinel(payload) = wrapped else {
            Issue.record("an audience embedding an unknown rule_type must fall to .sentinel, got \(wrapped)")
            return
        }
        let leaf = try Self.leafObject(fromAudienceSentinel: payload)
        #expect(
            Self.stringMember(named: "rule_type", in: leaf) == "bucketed_into_experience_key",
            "the sentinel-captured leaf must retain its rule_type discriminator"
        )
        #expect(
            Self.stringMember(named: "value", in: leaf) == "exp-a",
            "the sentinel-captured leaf must retain its target-experience-key value"
        )
        #expect(
            Self.boolMember(named: "negated", in: leaf) == false,
            "the sentinel-captured leaf must retain its negated flag"
        )
    }

    // MARK: - Requirement 3: happy-path parity (passes today — a regression lock, not new behavior)

    /// A config whose audiences carry ONLY known rule types must decode EXACTLY as today: nothing
    /// in the future degrading path may disturb the already-correct happy path. Unlike the tests
    /// above, this is a PARITY/regression lock — it already passes today (no unknown leaf is
    /// involved) and must continue to pass once GREEN lands, proving the fix is additive.
    @Test("a config with only known rule types decodes unchanged — no unexpected degradation")
    func happyPathAllKnownAudiencesDecodeUnchanged() throws {
        let first = Self.audienceWithLeafJSON(id: "aud-1", key: "k-1", leafJSON: Self.knownLeafJSON)
        let second = Self.audienceWithLeafJSON(id: "aud-2", key: "k-2", leafJSON: Self.knownLeafJSON)
        let config = try ProjectConfigFixtures.makeConfig(
            experiencesJSON: "[]",
            audiencesJSON: Self.audiencesArrayJSON([first, second])
        )

        let audiences = try #require(config.audiences, "an all-known-rule-type audiences array must decode")
        #expect(audiences.count == 2, "both known-leaf audiences must be retained")
        #expect(Set(audiences.map(\.id)) == ["aud-1", "aud-2"], "both audience ids must survive intact")

        let leaf = audiences.first { $0.id == "aud-1" }?.rules?.value1.OR?.first?.AND?.first?.OR_WHEN?.first
        guard case let .country(rule)? = leaf else {
            Issue.record("the known country leaf must decode to .country, got \(String(describing: leaf))")
            return
        }
        #expect(rule.value1.value2.value == "US", "the known leaf's matched country value must survive intact")
    }

    // MARK: - Requirement 4: never-throws / loop-termination

    /// A config containing an unknown-discriminator audience leaf must decode WITHOUT throwing and
    /// WITHOUT hanging — mirroring the `DegradingExperience` "LOOP-TERMINATION INVARIANT" comment
    /// (`ProjectConfig.swift:139-147`) that the eventual per-audience unkeyed-container loop must
    /// replicate. `ProjectConfig.init(from:)` already never throws for `audiences` today (the
    /// whole-array `try?` swallows the error into `nil` rather than propagating it), so the
    /// non-throwing half of this assertion is a plain synchronous call — no timeout mechanism is
    /// invented, per the dispatch's guidance to use only conventions already present in the repo.
    /// The MEANINGFUL RED signal in this test is the sibling-retention assertion that follows: it
    /// fails today because the whole array degrades to nil.
    @Test("decode of a config with an unknown-discriminator audience leaf terminates without throwing")
    func decodeWithUnknownLeafNeverThrowsAndRetainsSiblings() throws {
        let good = Self.audienceWithLeafJSON(id: "aud-good", key: "good", leafJSON: Self.knownLeafJSON)
        let bad = Self.audienceWithLeafJSON(id: "aud-bad", key: "bad", leafJSON: Self.unknownLeafJSON)
        let config = try ProjectConfigFixtures.makeConfig(
            experiencesJSON: "[]",
            audiencesJSON: Self.audiencesArrayJSON([good, bad])
        )

        // Non-throwing/termination half: reaching this line at all is the assertion — a plain
        // synchronous return, matching how ProjectConfig's degrading decode already behaves today.
        let retained = try #require(
            config.audiences,
            "decode must terminate AND retain the good sibling even with a bad leaf present"
        )
        #expect(retained.count == 2, "both the good and the preserved bad audience must survive decode")
    }

    // MARK: - JSONValue navigation helpers (test-local only — no Sources/ changes)
    // Mirrors the style of `ProjectConfig.stringValue(of:in:)` (Data/ProjectConfig.swift:263-268)
    // but is entirely test-local: reused by the evidence test above so it is written exactly once.

    /// Test-local navigation error for a `JSONValue` shape mismatch (readable `#require`/`throw`
    /// failures rather than force-unwrapping through the tree).
    private enum JSONValueNavigationError: Error {
        case missingMember(String)
        case missingElement(Int)
    }

    /// Navigates a `.sentinel` audience payload's `rules.OR[0].AND[0].OR_WHEN[0]` node — the fixed
    /// envelope `audienceWithLeafJSON` always wraps a leaf in — and returns it as a raw `JSONValue`
    /// (expected `.object`, matching the wire leaf shape).
    static func leafObject(fromAudienceSentinel payload: JSONValue) throws -> JSONValue {
        let rules = try member(named: "rules", in: payload)
        let orArray = try member(named: "OR", in: rules)
        let firstOr = try element(at: 0, in: orArray)
        let andArray = try member(named: "AND", in: firstOr)
        let firstAnd = try element(at: 0, in: andArray)
        let orWhenArray = try member(named: "OR_WHEN", in: firstAnd)
        return try element(at: 0, in: orWhenArray)
    }

    /// The `JSONValue` of the `name`-keyed member of an `.object` node, or throws when `value` is
    /// not an object or lacks that member.
    private static func member(named name: String, in value: JSONValue) throws -> JSONValue {
        guard case let .object(pairs) = value, let match = pairs.first(where: { $0.key == name })?.value else {
            throw JSONValueNavigationError.missingMember(name)
        }
        return match
    }

    /// The `JSONValue` at `index` of an `.array` node, or throws when `value` is not an array or
    /// the index is out of range.
    private static func element(at index: Int, in value: JSONValue) throws -> JSONValue {
        guard case let .array(values) = value, values.indices.contains(index) else {
            throw JSONValueNavigationError.missingElement(index)
        }
        return values[index]
    }

    /// The `String` value of the `name`-keyed member of an `.object` node, or `nil` when absent or
    /// not a JSON string.
    static func stringMember(named name: String, in value: JSONValue) -> String? {
        guard
            case let .object(pairs) = value,
            case let .string(string)? = pairs.first(where: { $0.key == name })?.value
        else {
            return nil
        }
        return string
    }

    /// The `Bool` value of the `name`-keyed member of an `.object` node, or `nil` when absent or not
    /// a JSON boolean.
    static func boolMember(named name: String, in value: JSONValue) -> Bool? {
        guard
            case let .object(pairs) = value,
            case let .bool(bool)? = pairs.first(where: { $0.key == name })?.value
        else {
            return nil
        }
        return bool
    }
}
