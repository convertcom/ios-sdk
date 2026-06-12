// Tests/ConvertSDKCoreTests/Support/ProjectConfigFixtures.swift
// Shared `ProjectConfig` builders for the `ExperienceManager` suite (Epic 3 / Story 4).
//
// ── Why decode wire JSON (NOT a memberwise init) ─────────────────────────────────────────
// `ProjectConfig` is `Decodable`-only — it exposes NO public memberwise initializer (it owns a
// degrading `init(from:)` and nothing else). The sanctioned way to construct one in a test is to
// decode a JSON literal through the runtime `JSONDecoder`, exactly as `ConfigStoreTests.makeConfig`
// and `ProjectConfigTests` do. These builders therefore assemble the `ConfigResponseData` wire
// envelope and decode it, so the fixtures also pin the on-the-wire shape the EM pipeline reads.
//
// ── Why an `enum` namespace ──────────────────────────────────────────────────────────────
// Three test files already declare file-private `makeConfig` helpers. To avoid any cross-file
// ambiguity these builders live under the `ProjectConfigFixtures` enum (a pure namespace, mirroring
// the `RuleAdapter` enum-as-namespace precedent) rather than as bare top-level functions.
//
// ── Wire shapes (verified against the generated `ConfigSchemas.swift`) ────────────────────
//   * `ConfigExperience` keys are literal: `id`, `key`, `audiences` ([String] ids), `locations`
//     ([String] ids), `type`, `variations`. Each variation is `{id, key, traffic_allocation}` where
//     `traffic_allocation` is a 0–100 percentage (`alloc: 100` ⇒ a sole full-traffic variation).
//   * `ConfigAudience.rules` is an allOf wrapper whose `init(from:)` decodes its inner
//     `RuleObjectAudience` from the SAME object — so on the wire the `rules` value IS the audience
//     rule graph directly: `{"OR":[{"AND":[{"OR_WHEN":[ <leaf> ]}]}]}`. The country leaf shape
//     `{"rule_type":"country","value":"US","matching":{"match_type":"equals"}}` is the one
//     `RuleAdapterTests` proves decodes end-to-end through `RuleManager` + `Comparisons` (the
//     `country`/`equals` operator is live in `Comparisons.comparators`).
//
// ── SonarQube `new_duplicated_lines_density` (3% gate) ───────────────────────────────────
// Every envelope/experience/audience literal is written EXACTLY once here and shared across all EM
// tests; no test body re-inlines a ≥10-line JSON block. CPD is token-based, so centralizing the
// literals (not just renaming) is what keeps the diff under the gate.

import Foundation
@testable import ConvertSDKCore

/// Shared `ProjectConfig` builders for the `ExperienceManager` suite. Pure namespace — every
/// member is `static`; the type is never instantiated.
enum ProjectConfigFixtures {

    /// Decodes a `ProjectConfig` from the `ConfigResponseData` wire envelope, splicing in the
    /// caller-supplied array fragments. Unrelated arrays default to `[]` (which decodes to an empty
    /// typed array — never a degrade), so a test that cares only about experiences need not spell
    /// out audiences/locations. Throws only if the spliced JSON is malformed (a test-authoring bug),
    /// since `ProjectConfig.init(from:)` itself degrades rather than throws.
    static func makeConfig(
        experiencesJSON: String,
        audiencesJSON: String = "[]",
        locationsJSON: String = "[]"
    ) throws -> ProjectConfig {
        let envelope = """
        {"account_id":"a","project":{"id":"p"},\
        "experiences":\(experiencesJSON),\
        "audiences":\(audiencesJSON),\
        "locations":\(locationsJSON)}
        """
        return try JSONDecoder().decode(ProjectConfig.self, from: Data(envelope.utf8))
    }

    /// One `ConfigExperience` JSON object carrying the FULL shape the EM pipeline reads: `id`, `key`,
    /// a known `type`, a single-variation `variations` array (`{id, key, traffic_allocation}`), and
    /// optional `audiences` / `locations` ID arrays. `alloc` is the variation's 0–100 traffic
    /// percentage — pass `100` for a sole full-traffic variation that always buckets.
    ///
    /// - Parameters:
    ///   - id: The experience's wire `id` (the `experienceId` the pipeline keys sticky/persist on).
    ///   - key: The experience's wire `key` (what `fullExperience(forKey:)` looks up).
    ///   - variationId: The sole variation's wire `id` (what bucketing returns / sticky restores).
    ///   - variationKey: The sole variation's wire `key`.
    ///   - alloc: The variation's 0–100 traffic percentage.
    ///   - audiences: Audience ID strings to gate on (empty ⇒ audience gate bypassed/unrestricted).
    ///   - locations: Location ID strings to gate on (empty ⇒ location gate bypassed/unrestricted).
    static func experienceJSON(
        id: String,
        key: String,
        variationId: String,
        variationKey: String,
        alloc: Int,
        audiences: [String] = [],
        locations: [String] = []
    ) -> String {
        """
        {"id":"\(id)","key":"\(key)","type":"a/b",\
        "audiences":\(idArrayJSON(audiences)),\
        "locations":\(idArrayJSON(locations)),\
        "variations":[{"id":"\(variationId)","key":"\(variationKey)",\
        "traffic_allocation":\(alloc)}]}
        """
    }

    /// One `ConfigAudience` JSON object whose `rules` graph is a single `country == <value>` leaf.
    /// The `rules` value is the `RuleObjectAudience` directly (allOf flattening), wrapping the leaf in
    /// the fixed `OR → AND → OR_WHEN` envelope so `RuleAdapter.flatten` + `RuleManager.evaluate`
    /// pass/fail purely on `attributes["country"]`.
    ///
    /// - Parameters:
    ///   - id: The audience's wire `id` (referenced from an experience's `audiences` array).
    ///   - key: The audience's wire `key`.
    ///   - countryEquals: The country code the leaf matches with the `equals` operator.
    static func audienceJSON(id: String, key: String, countryEquals: String) -> String {
        """
        {"id":"\(id)","key":"\(key)","type":"transient","rules":\
        {"OR":[{"AND":[{"OR_WHEN":[\
        {"rule_type":"country","value":"\(countryEquals)",\
        "matching":{"match_type":"equals"}}\
        ]}]}]}}
        """
    }

    /// Renders a list of ID strings as a JSON string array (`["a","b"]`; `[]` when empty). Centralized
    /// so the experience builder never inlines the quoting/joining logic per call.
    private static func idArrayJSON(_ ids: [String]) -> String {
        "[" + ids.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    // MARK: - Convenience builders (one call → a decoded ProjectConfig)
    //
    // These wrap `makeConfig` + `experienceJSON` (+ `audienceJSON`) so a test makes ONE call and gets
    // a `ProjectConfig` back — no test nests a multi-line `experienceJSON(...)` call inside a string
    // interpolation (a single-line `"..."` literal cannot span newlines). They also keep the
    // array-splice (`[ <experience> ]`) in exactly one place, tightening the SonarQube 3% margin.

    /// A `ProjectConfig` containing exactly ONE experience and NO audiences/locations (so its audience
    /// and location gates are unrestricted). Used by the unknown-key, empty-audience, and
    /// `enableTracking`/fire scenarios. `alloc` defaults to 100 (a sole full-traffic variation that
    /// always buckets); the sticky scenario passes its own `variationId`.
    static func singleExperienceConfig(
        experienceId: String = "exp-1",
        key: String,
        variationId: String = "var-1",
        variationKey: String = "control",
        alloc: Int = 100
    ) throws -> ProjectConfig {
        let experience = experienceJSON(
            id: experienceId,
            key: key,
            variationId: variationId,
            variationKey: variationKey,
            alloc: alloc
        )
        return try makeConfig(experiencesJSON: "[\(experience)]")
    }

    /// A `ProjectConfig` whose single experience is gated on a `country == countryEquals` audience —
    /// the experience references the audience by id and the audience carries the matching country
    /// leaf. Drives the audience-pass / audience-fail scenarios off `attributes["country"]`.
    static func countryGatedExperienceConfig(
        experienceId: String = "exp-1",
        key: String,
        variationId: String = "var-1",
        variationKey: String = "control",
        audienceId: String = "aud-country",
        countryEquals: String
    ) throws -> ProjectConfig {
        let experience = experienceJSON(
            id: experienceId,
            key: key,
            variationId: variationId,
            variationKey: variationKey,
            alloc: 100,
            audiences: [audienceId]
        )
        let audience = audienceJSON(id: audienceId, key: "\(audienceId)-key", countryEquals: countryEquals)
        return try makeConfig(experiencesJSON: "[\(experience)]", audiencesJSON: "[\(audience)]")
    }

    /// A `ProjectConfig` holding `count` experiences in DETERMINISTIC config order, keyed
    /// `"exp-1"`…`"exp-{count}"` with ids `"id-1"`…`"id-{count}"`, variation ids `"var-1"`…
    /// `"var-{count}"`, and variation keys `"control-1"`…`"control-{count}"`. Each is a sole
    /// full-traffic (100%) variation so an eligible experience always buckets.
    ///
    /// By default every experience is no-audience (unrestricted) and therefore eligible — the
    /// bulk-selection happy path. When `gatedFailCountry` is non-`nil`, ONLY the FIRST experience
    /// (`"exp-1"` / `"id-1"`) is gated on a `country == gatedFailCountry` audience; the rest stay
    /// unrestricted. Calling the bulk selector with `attributes["country"]` set to anything OTHER
    /// than `gatedFailCountry` then fails exactly that one experience's gate, so the result holds
    /// `count - 1` variations — the audience-fail-exclusion scenario.
    ///
    /// Composes `experienceJSON` once per index (and `audienceJSON` once for the gated leaf),
    /// splicing the array fragments through a single `makeConfig` call — the envelope and the
    /// single-experience builder's internals are never re-inlined (SonarQube 3% gate; CPD is
    /// token-based, so reuse — not renaming — is what keeps this under the threshold).
    ///
    /// - Parameters:
    ///   - count: How many experiences to emit (≥ 1 for a meaningful config).
    ///   - gatedFailCountry: When set, `"exp-1"` is gated on `country == <value>`; the rest are
    ///     unrestricted. `nil` (the default) leaves every experience eligible.
    static func multiExperienceConfig(count: Int, gatedFailCountry: String? = nil) throws -> ProjectConfig {
        let gateAudienceId = "aud-gate-1"
        let experiences = (1...count).map { index in
            experienceJSON(
                id: "id-\(index)",
                key: "exp-\(index)",
                variationId: "var-\(index)",
                variationKey: "control-\(index)",
                alloc: 100,
                audiences: (index == 1 && gatedFailCountry != nil) ? [gateAudienceId] : []
            )
        }
        let experiencesJSON = "[" + experiences.joined(separator: ",") + "]"
        guard let gatedFailCountry else {
            return try makeConfig(experiencesJSON: experiencesJSON)
        }
        let audience = audienceJSON(
            id: gateAudienceId, key: "\(gateAudienceId)-key", countryEquals: gatedFailCountry
        )
        return try makeConfig(experiencesJSON: experiencesJSON, audiencesJSON: "[\(audience)]")
    }
}
