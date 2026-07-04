// Tests/ConvertSwiftSDKCoreTests/Bucketing/AnchoredBucketingParityTests.swift
// Cross-SDK anchored/packed bucketing parity suite for qs-01 (cross-SDK bucketing contract v12).
// Spec of record: `2026-06-09-convert-ios-sdk/qs-01-anchored-bucketing-layout.md`.
//
// ── Why a NEW file (not an extension of HashParityTests.swift) ───────────────────────────
// `HashParityTests.swift` drives `MurmurHash3` + `BucketingManager.selectBucket` (the PACKED
// selector) directly over `hash-parity-vectors.json` (hash+selectBucket only, no version gate, no
// ConfigExperience). `cross-sdk-bucketing-vectors.json` is structurally different: it carries a
// full `{experienceId, visitorId, version, variations:[{id, traffic_allocation, status?}]}` shape
// and must be driven end-to-end through the version-gated entry point
// (`BucketingManager.bucketVersionGated`), asserting the resolved variation id/nil. Different
// fixture shape, different subject under test → a separate file. The AC1/AC4/AC5/AC6/AC8/AC9
// focused tests (not derivable from this fixture alone) live in the sibling
// `AnchoredBucketingGateAndBoundaryTests.swift` — kept out of THIS file to stay under SwiftLint's
// `file_length`/`type_body_length` gates.
//
// ── Decodable types at FILE scope, not nested in the `@Suite` struct ──────────────────────
// `VariationVector`/`Vector` sit at file scope (not nested inside `AnchoredBucketingParityTests`)
// so `VariationVector`'s `CodingKeys` enum is only ONE level of nesting deep — nesting them inside
// the suite struct as well would put `CodingKeys` two levels deep, tripping SwiftLint's `nesting`
// rule (max 1 level).
//
// ── Parity coverage ───────────────────────────────────────────────────────────────────────
// All 59 golden vectors resolve through `bucketVersionGated`: v12 (anchored, `version > 11`)
// vectors route to `AnchoredBucketing.selectBucket`; v11 (packed) vectors delegate verbatim to
// the existing `bucket(...)` (AC6). The packed `eligible` walk (`BucketingManager.bucket`, step 5)
// defaults an omitted/NaN `traffic_allocation` to 100.0, matching the anchored pass and the JS
// reference's `data-manager.ts:575` builder — see `qs-01-decision-log.md` for the write-up.
//
// ── SonarQube `new_duplicated_lines_density` discipline ───────────────────────────────────
// ONE parameterized `@Test(arguments:)` drives all 59 golden vectors — no per-vector duplication.

import Foundation
import Testing
@testable import ConvertSwiftSDKCore

/// One variation entry inside a golden vector's `variations` array. `trafficAllocation` mirrors
/// the wire's snake_case `traffic_allocation` via explicit `CodingKeys` (kept camelCase in Swift,
/// unlike the generated schema's own snake_case property, to stay SwiftLint-clean in a
/// non-generated file). `status` is decoded as the raw wire String and mapped onto
/// `Components.Schemas.VariationStatuses` when building a real config.
struct AnchoredVariationVector: Decodable, Sendable {
    let id: String
    let trafficAllocation: Double?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id
        case trafficAllocation = "traffic_allocation"
        case status
    }
}

/// One golden vector, decoded straight from `cross-sdk-bucketing-vectors.json`. `expected` is the
/// resolved variation id, or `nil` for a not-bucketed vector.
struct AnchoredBucketingVector: Decodable, Sendable {
    let description: String
    let experienceId: String
    let visitorId: String
    let version: Double
    let variations: [AnchoredVariationVector]
    let expected: String?
}

@Suite("AnchoredBucketingParity")
struct AnchoredBucketingParityTests {

    /// The decoded golden vectors, loaded from the `Fixtures/` resource directory (same bundling
    /// mechanism as `HashParityTests.vectors` — `resources: [.copy("Fixtures")]` on the
    /// `ConvertSwiftSDKCoreTests` target in `Package.swift`). Fully defensive load (`try?`
    /// throughout, `?? []` on failure): the lint gate forbids `!`/`try!`/`fatalError`
    /// (`force_unwrapping`), and a static `let` initializer cannot `throw`. The `fixtureLoaded`
    /// guard test below converts a failed/partial load into a LOUD failure instead of a
    /// vacuously-passing empty parameterized suite.
    static let vectors: [AnchoredBucketingVector] = {
        guard
            let url = Bundle.module.url(
                forResource: "cross-sdk-bucketing-vectors",
                withExtension: "json",
                subdirectory: "Fixtures"
            ),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([AnchoredBucketingVector].self, from: data)
        else {
            return []
        }
        return decoded
    }()

    /// Guard test: the fixture loaded and carries the full committed 59-vector set (AC7). If the
    /// bundled resource is missing or fails to decode, `vectors` is empty and the parameterized
    /// parity test below would pass vacuously — this asserts the count so that case fails LOUDLY.
    @Test("fixture loaded — all 59 committed cross-SDK vectors decode")
    func fixtureLoaded() {
        #expect(
            Self.vectors.count >= 59,
            "expected >= 59 cross-SDK vectors, loaded \(Self.vectors.count) — fixture missing or failed to decode"
        )
    }

    /// Builds a `Components.Schemas.ConfigExperience` from one golden vector, preserving config
    /// order and passing EVERY variation through unfiltered (active and inactive, with or without
    /// `traffic_allocation`) — the anchored pass interprets activity itself; only the packed
    /// `eligible` walk pre-filters.
    private func makeExperience(from vector: AnchoredBucketingVector) -> Components.Schemas.ConfigExperience {
        let variations = vector.variations.map { entry in
            Components.Schemas.ExperienceVariationConfig(
                id: entry.id,
                traffic_allocation: entry.trafficAllocation,
                status: entry.status.flatMap(Components.Schemas.VariationStatuses.init(rawValue:))
            )
        }
        return Components.Schemas.ConfigExperience(
            id: vector.experienceId,
            version: vector.version,
            variations: variations
        )
    }

    /// THE parity assertion (AC7). For each vector: build the experience, run it through
    /// `bucketVersionGated` (the version-gated entry point qs-01 introduces), and assert the
    /// resolved variation id — or `nil` for a not-bucketed vector — matches `expected`. One body
    /// covers all 59 vectors (no per-vector duplication). `enableTracking: false` — this suite
    /// asserts SELECTION, not the enqueue (that is AC9's job, isolated in the sibling file).
    @Test("cross-SDK anchored/packed parity vector (AC7)", arguments: vectors)
    func parity(_ vector: AnchoredBucketingVector) async {
        let experience = makeExperience(from: vector)
        let manager = BucketingManager(eventSink: MockEventSink(), logger: MockLogger())
        let result = await manager.bucketVersionGated(
            visitorId: vector.visitorId, experience: experience, enableTracking: false
        )
        let message = "\(vector.description): got \(String(describing: result?.id)), "
            + "expected \(String(describing: vector.expected))"
        #expect(result?.id == vector.expected, Comment(rawValue: message))
    }
}
