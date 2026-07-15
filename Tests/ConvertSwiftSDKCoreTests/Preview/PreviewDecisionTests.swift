// Tests/ConvertSwiftSDKCoreTests/Preview/PreviewDecisionTests.swift
// RED-phase suite for `PreviewDecision` (qs-02 Experiment Preview, contract §2 — "Decision"
// clause / AC4 / AC5), task IOS-3.
//
// `PreviewDecision` does NOT exist yet (Sources/ConvertSwiftSDKCore/Preview/PreviewDecision.swift
// is unwritten). This file MUST fail to compile against the missing `PreviewDecision` symbol —
// that is the expected, correct RED state. The vectors below pin the contract the to-be-built
// GREEN-phase primitive has to satisfy.
//
// SCOPE (IOS-3 — narrower than the full qs-02 preview surface): this is the pure Core-only
// decision-matching primitive, isolated from config fetch, `ConvertContext`, and tracking. Its
// signature takes ONLY `(experience, variationId)` — no `visitorId`, no decision-store input.
// Because sticky decisions and the bucketing hash are not reachable inputs, the "bypass stored
// decisions / the bucketing hash" half of contract §2's Decision clause is a STRUCTURAL,
// type-signature-level guarantee here, not a runtime check — this file cannot (and does not
// attempt to) construct a "visitor with a different persisted sticky decision" scenario, because
// the primitive has no visitorId/store parameter to seed one. That AC5 sub-case is exercised at
// the `ConvertContext` layer in a later task (IOS-5), where the preview-aware call site sits in
// front of `DecisionStore`/`BucketingManager` and is proven to never reach either.
//
// Contract pinned by this suite (GREEN-phase implementation must satisfy exactly):
//   `public enum PreviewDecision { public static func forcedVariation(
//       for experience: Components.Schemas.ConfigExperience,
//       variationId: String
//   ) -> Variation? }`
//   in `Sources/ConvertSwiftSDKCore/Preview/PreviewDecision.swift` (sibling to `PreviewParam`).
//
//   - Matches `variationId` against `experience.variations` by `id` and returns a `Variation`
//     in the SAME shape `BucketingManager.bucket`/`bucketVersionGated` build from a normal
//     bucketed decision (verified at `Sources/ConvertSwiftSDKCore/Bucketing/BucketingManager.swift:118-123`
//     and `:205-210`): `Variation(id: matched.id ?? "", key: matched.key ?? "", experienceId:
//     experience.id, experienceKey: experience.key)` — EXCEPT `experience.key`/`experience.id`,
//     which (qs-02 Fix 3) is inert-on-bad-input rather than degraded: a nil OR empty
//     `experience.key`/`experience.id` returns `nil`, the SAME signal as an unmatched
//     `variationId`, instead of building a `Variation` with an empty `experienceKey` that would
//     poison `ConvertContext.runExperiences`' sibling filter and could never be matched by
//     `runExperience`'s `experienceKey == key` short-circuit.
//   - MUST bypass experience status/environment and variation status/traffic by construction:
//     the signature has no attributes/environment/locationProperties parameter for a rule gate
//     to consult, and no visitorId/hash-seed input for a bucketing walk to run — status/traffic/
//     environment fields on the fixtures below are set to actively-hostile values (draft, paused,
//     mismatched environment, stopped, zero-traffic) specifically to prove the match is untouched
//     by them, not merely "unset".
//   - MUST NOT call `BucketingManager` or `ExperienceManager.selectVariation` (a GREEN-phase
//     implementation constraint — not independently testable here without spy infrastructure,
//     which is out of scope for this primitive; the structural signature above is the enforcement
//     mechanism: neither collaborator is reachable without a visitorId/store to pass them).
//   - Returns `nil` when `variationId` is not present in `experience.variations`, OR
//     `experience.key`/`experience.id` is nil/empty (inert-on-bad-input signal). The primitive
//     itself must not log or throw — the warning-log + "context behaves fully normally" wiring
//     around this `nil` is deferred to task IOS-5.
//
// SonarQube `new_duplicated_lines_density` (3% gate): every scenario rides ONE parameterized
// `@Test(arguments:)` over a single `forcedVariationCases` table, built from two shared
// `makeExperience`/`makeVariation` fixture builders (mirroring the `BucketingManagerTests`
// `makeExperience` precedent) — no test re-wires `Components.Schemas.ConfigExperience` inline.
//
// NOTE: `Variation` is `Codable & Sendable & Identifiable` but NOT `Equatable`, so `#expect(==)`
// cannot compare it directly (same situation `PreviewParamTests` hit with its parsed-pair tuple).
// Each case's expectation is expressed as an optional `ExpectedVariation` (a local, `Equatable`,
// `Sendable` value type); the actual `Variation` result is mapped into one before comparison.

import Foundation
import Testing
@testable import ConvertSwiftSDKCore

@Suite("PreviewDecision")
struct PreviewDecisionTests {

    /// Comparable stand-in for `Variation`'s four fields, since `Variation` does not conform to
    /// `Equatable`.
    struct ExpectedVariation: Equatable, Sendable {
        let id: String
        let key: String
        let experienceId: String
        let experienceKey: String
    }

    /// One variation spec for ``makeExperience`` — deliberately allows hostile
    /// status/traffic values (non-running, zero-traffic) so the fixtures can prove the
    /// primitive never consults them. Mirrors the `VariationSpec` precedent in
    /// `BucketingManagerTests`.
    private struct VariationSpec: Sendable {
        let id: String
        let key: String
        let trafficAllocation: Double
        let status: Components.Schemas.VariationStatuses
    }

    /// One forced-decision test vector.
    struct ForcedVariationCase: Sendable {
        let description: String
        let experience: Components.Schemas.ConfigExperience
        let variationId: String
        let expected: ExpectedVariation?
    }

    // MARK: - Shared fixture builders (SonarQube 3% gate — declared once, reused per case)

    /// Builds a ``Components.Schemas.ConfigExperience`` with the given `id`/`key`/`status`/
    /// `environment` and a `variations` list assembled from ``VariationSpec`` entries — relying
    /// on the generated memberwise inits (unlisted fields default to `nil`). `status` and
    /// `environment` are exposed as knobs so a case can set them to values that would fail a
    /// normal decision (draft/paused status, a mismatched environment) while still expecting the
    /// forced variation back.
    private static func makeExperience(
        id: String?,
        key: String?,
        status: Components.Schemas.ExperienceStatuses? = nil,
        environment: String? = nil,
        variations: [VariationSpec]
    ) -> Components.Schemas.ConfigExperience {
        let configs = variations.map { spec in
            Components.Schemas.ExperienceVariationConfig(
                id: spec.id,
                key: spec.key,
                traffic_allocation: spec.trafficAllocation,
                status: spec.status
            )
        }
        return Components.Schemas.ConfigExperience(
            id: id,
            key: key,
            status: status,
            variations: configs,
            environment: environment
        )
    }

    // MARK: - Case table

    /// Covers AC4 (forced decision) and the status/environment/traffic bypass half of AC5 (the
    /// sticky-decision sub-case is deferred to IOS-5 per the file-header note). Each hostile-state
    /// case targets exactly one experience/variation, set up so a NORMAL decision pipeline
    /// (`ExperienceManager.selectVariation` / `BucketingManager`) would refuse or never reach it —
    /// `forcedVariation` must return it anyway, in the standard `Variation` shape.
    static let forcedVariationCases: [ForcedVariationCase] = [
        // --- AC5: draft-status experience — status bypass ---
        ForcedVariationCase(
            description: "draft-status experience still forces the requested variation",
            experience: makeExperience(
                id: "exp-draft",
                key: "exp-draft-key",
                status: .draft,
                variations: [
                    VariationSpec(id: "var-1", key: "control", trafficAllocation: 100, status: .running),
                    VariationSpec(id: "var-2", key: "treatment", trafficAllocation: 100, status: .running)
                ]
            ),
            variationId: "var-2",
            expected: ExpectedVariation(
                id: "var-2", key: "treatment", experienceId: "exp-draft", experienceKey: "exp-draft-key"
            )
        ),

        // --- AC5: paused experience — status bypass ---
        ForcedVariationCase(
            description: "paused experience still forces the requested variation",
            experience: makeExperience(
                id: "exp-paused",
                key: "exp-paused-key",
                status: .paused,
                variations: [
                    VariationSpec(id: "var-1", key: "control", trafficAllocation: 100, status: .running)
                ]
            ),
            variationId: "var-1",
            expected: ExpectedVariation(
                id: "var-1", key: "control", experienceId: "exp-paused", experienceKey: "exp-paused-key"
            )
        ),

        // --- AC5: mismatched environment — no environment parameter exists to gate on ---
        ForcedVariationCase(
            description: "experience with a mismatched environment still forces the requested variation",
            experience: makeExperience(
                id: "exp-env",
                key: "exp-env-key",
                status: .active,
                environment: "staging-only",
                variations: [
                    VariationSpec(id: "var-1", key: "control", trafficAllocation: 100, status: .running)
                ]
            ),
            variationId: "var-1",
            expected: ExpectedVariation(
                id: "var-1", key: "control", experienceId: "exp-env", experienceKey: "exp-env-key"
            )
        ),

        // --- AC5: non-running (stopped) variation — variation-status bypass ---
        ForcedVariationCase(
            description: "a stopped (non-running) target variation is still forced",
            experience: makeExperience(
                id: "exp-stopped",
                key: "exp-stopped-key",
                status: .active,
                variations: [
                    VariationSpec(id: "var-1", key: "control", trafficAllocation: 50, status: .stopped)
                ]
            ),
            variationId: "var-1",
            expected: ExpectedVariation(
                id: "var-1", key: "control", experienceId: "exp-stopped", experienceKey: "exp-stopped-key"
            )
        ),

        // --- AC5: zero-traffic target variation — traffic-filter bypass ---
        ForcedVariationCase(
            description: "a zero-traffic target variation is still forced",
            experience: makeExperience(
                id: "exp-zero-traffic",
                key: "exp-zero-traffic-key",
                status: .active,
                variations: [
                    VariationSpec(id: "var-1", key: "control", trafficAllocation: 0, status: .running)
                ]
            ),
            variationId: "var-1",
            expected: ExpectedVariation(
                id: "var-1",
                key: "control",
                experienceId: "exp-zero-traffic",
                experienceKey: "exp-zero-traffic-key"
            )
        ),

        // --- AC4/AC5 combined: every hostile condition stacked on the SAME experience/variation ---
        ForcedVariationCase(
            description: "draft status + mismatched environment + non-running + zero-traffic, all "
                + "stacked, still force the requested variation (full-bypass proof)",
            experience: makeExperience(
                id: "exp-combo",
                key: "exp-combo-key",
                status: .draft,
                environment: "staging-only",
                variations: [
                    VariationSpec(id: "var-1", key: "control", trafficAllocation: 0, status: .stopped)
                ]
            ),
            variationId: "var-1",
            expected: ExpectedVariation(
                id: "var-1", key: "control", experienceId: "exp-combo", experienceKey: "exp-combo-key"
            )
        ),

        // --- inert-on-bad-input: unknown variationId -> nil ---
        ForcedVariationCase(
            description: "unknown variationId not present in the experience's variations -> nil",
            experience: makeExperience(
                id: "exp-unknown",
                key: "exp-unknown-key",
                status: .active,
                variations: [
                    VariationSpec(id: "var-1", key: "control", trafficAllocation: 100, status: .running)
                ]
            ),
            variationId: "does-not-exist",
            expected: nil
        ),

        // --- inert-on-bad-input (qs-02 Fix 3): nil experience.key -> nil, even on a matching
        // variationId — a `Variation` with an empty `experienceKey` would poison
        // `runExperiences`' sibling filter and could never be matched by `runExperience`'s
        // `experienceKey == key` short-circuit. ---
        ForcedVariationCase(
            description: "nil experience.key with an otherwise-matching variationId -> nil",
            experience: makeExperience(
                id: "exp-nil-key",
                key: nil,
                status: .active,
                variations: [
                    VariationSpec(id: "var-1", key: "control", trafficAllocation: 100, status: .running)
                ]
            ),
            variationId: "var-1",
            expected: nil
        ),

        // --- inert-on-bad-input (qs-02 Fix 3): empty experience.key -> nil (same as nil). ---
        ForcedVariationCase(
            description: "empty experience.key with an otherwise-matching variationId -> nil",
            experience: makeExperience(
                id: "exp-empty-key",
                key: "",
                status: .active,
                variations: [
                    VariationSpec(id: "var-1", key: "control", trafficAllocation: 100, status: .running)
                ]
            ),
            variationId: "var-1",
            expected: nil
        ),

        // --- inert-on-bad-input (qs-02 Fix 3): nil experience.id -> nil, even on a matching
        // variationId and a non-empty key. ---
        ForcedVariationCase(
            description: "nil experience.id with an otherwise-matching variationId -> nil",
            experience: makeExperience(
                id: nil,
                key: "exp-nil-id-key",
                status: .active,
                variations: [
                    VariationSpec(id: "var-1", key: "control", trafficAllocation: 100, status: .running)
                ]
            ),
            variationId: "var-1",
            expected: nil
        ),

        // --- inert-on-bad-input (qs-02 Fix 3): empty experience.id -> nil (same as nil). ---
        ForcedVariationCase(
            description: "empty experience.id with an otherwise-matching variationId -> nil",
            experience: makeExperience(
                id: "",
                key: "exp-empty-id-key",
                status: .active,
                variations: [
                    VariationSpec(id: "var-1", key: "control", trafficAllocation: 100, status: .running)
                ]
            ),
            variationId: "var-1",
            expected: nil
        )
    ]

    @Test("forcedVariation", arguments: forcedVariationCases)
    func forcedVariation(_ caseUnderTest: ForcedVariationCase) {
        let result = PreviewDecision.forcedVariation(
            for: caseUnderTest.experience,
            variationId: caseUnderTest.variationId
        )
        let actual = result.map {
            ExpectedVariation(
                id: $0.id, key: $0.key, experienceId: $0.experienceId, experienceKey: $0.experienceKey
            )
        }
        let got = String(describing: actual)
        let want = String(describing: caseUnderTest.expected)
        #expect(
            actual == caseUnderTest.expected,
            "\(caseUnderTest.description): got \(got), expected \(want)"
        )
    }
}
