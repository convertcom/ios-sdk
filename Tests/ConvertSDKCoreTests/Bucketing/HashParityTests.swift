// Tests/ConvertSDKCoreTests/Bucketing/HashParityTests.swift
// Cross-SDK bucketing PARITY SUITE (Epic 3 / Story 2 — deterministic bucketing).
//
// Drives the verified-correct MurmurHash3 (x86, 32-bit) + BucketingManager.selectBucket
// implementations over the committed golden vectors captured from the Convert JavaScript SDK,
// proving byte-for-byte cross-SDK agreement. This is the gate every downstream bucketing
// decision rides on: it MUST pass 100% of vectors (AC15).
//
// VECTOR CONTRACT (each element of Fixtures/hash-parity-vectors.json):
//   * hash key      = "<experienceId><visitorId>" — experience id FIRST, visitor id second,
//     NO separator — fed as UTF-8 bytes to MurmurHash3 seeded with the vector's OWN `seed`
//     (NOT a fixed seed: three vectors carry seeds 0 / 12345 / 2147483647, the rest 9999).
//   * expectedValue = the 0..<10000 bucket value the JS SDK projected the hash onto via
//     Int(Double(hash) / Double(maxHash) * Double(maxTraffic)).
//   * buckets       = { <variationKey>: <0-100 PERCENTAGE> }. selectBucket consumes 0..<10000
//     bucket-units, so each percentage is scaled ×100 before selection.
//   * expectedVariationId = the variation key the JS SDK selected for that bucket value.
//
// KEY-ORDER NOTE — selectBucket walks `weights` in order (accumulate-first-wins), and the JS
// SDK iterated the vectors' bucket objects in JSON insertion order. Swift `[String: Int]` is
// UNORDERED, so insertion order is not preserved through decoding. This is safe here because
// EVERY one of the 74 committed vectors uses the two-way split {"varA","varB"} whose insertion
// order (varA, varB) is identical to alphabetical order — so `.sorted { $0.key < $1.key }`
// reproduces the JS iteration order exactly. Verified empirically: under sorted-keys, all 74
// vectors reproduce both their expectedValue and expectedVariationId with zero mismatches. If a
// future vector ever introduced keys whose insertion order differs from alphabetical, this
// fixture-shaped assumption would need replacing with an insertion-order-preserving decode.
//
// SonarQube `new_duplicated_lines_density` (3% gate, AC15): ONE parameterized parity @Test
// covers all 74 vectors (no per-vector duplication), plus a single non-parameterized
// `fixtureLoaded` guard @Test that fails LOUDLY if the fixture can't be loaded (so an empty
// `arguments:` array can never let the parity test pass vacuously).

import Foundation
import Testing
@testable import ConvertSDKCore

@Suite("HashParity")
struct HashParityTests {

    /// One cross-SDK golden vector, decoded straight from `hash-parity-vectors.json`. `Sendable`
    /// (a pure value type) so it can be passed through swift-testing's `arguments:`.
    struct ParityVector: Decodable, Sendable {
        let description: String
        let visitorId: String
        let experienceId: String
        let seed: UInt32
        let expectedValue: Int
        let expectedVariationId: String
        let buckets: [String: Int]
    }

    /// The decoded golden vectors. Loaded from the bundled `Fixtures/` resource directory
    /// (wired via `resources: [.copy("Fixtures")]` on the `ConvertSDKCoreTests` target in
    /// Package.swift, so `Bundle.module` resolves it — the same path `ConfigDecodeTests` and
    /// `ProjectConfigTests` already use for their captures).
    ///
    /// `arguments:` needs a concrete array at parameterization time, and a static `let`
    /// initializer cannot `throw` / `#require`; the lint gate also forbids `!` / `try!` /
    /// `fatalError` (`force_unwrapping`). So the load is fully defensive (`try?` throughout,
    /// `?? []` on failure) — and the `fixtureLoaded` guard test below asserts `count >= 74`,
    /// converting any failed/partial load into a LOUD, explicit failure instead of a parity
    /// suite that silently passes on an empty argument list.
    static let vectors: [ParityVector] = {
        guard
            let url = Bundle.module.url(
                forResource: "hash-parity-vectors",
                withExtension: "json",
                subdirectory: "Fixtures"
            ),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([ParityVector].self, from: data)
        else {
            return []
        }
        return decoded
    }()

    /// Guard test: the fixture loaded and carries the full committed vector set. If the bundled
    /// resource is missing or fails to decode, `vectors` is empty and the parameterized parity
    /// test below would pass vacuously — this asserts the count so that case fails LOUDLY here.
    @Test("fixture loaded — all 74 committed vectors decode")
    func fixtureLoaded() {
        #expect(
            Self.vectors.count >= 74,
            "expected >= 74 parity vectors, loaded \(Self.vectors.count) — fixture missing or failed to decode"
        )
    }

    /// THE parity assertion (AC15). For each vector: hash "<experienceId><visitorId>" (id first,
    /// no separator) with the vector's OWN seed, project onto 0..<10000 with the production
    /// formula, and assert the bucket value matches. Then scale the 0-100 fixture buckets to
    /// 0..<10000 bucket-units (×100) in sorted-key order and assert `selectBucket` picks the JS
    /// SDK's expected variation. One body covers all 74 vectors (no per-vector duplication).
    @Test("cross-SDK parity vector", arguments: vectors)
    func parity(_ vector: ParityVector) {
        // Hash: experienceId FIRST then visitorId, no separator, the vector's own seed.
        let input = Array("\(vector.experienceId)\(vector.visitorId)".utf8)
        let hash = MurmurHash3.hash(input, seed: vector.seed)
        let bucketValue = Int(
            Double(hash) / Double(Defaults.maxHash) * Double(Defaults.maxTraffic)
        )
        #expect(
            bucketValue == vector.expectedValue,
            "bucket value mismatch for \(vector.description): got \(bucketValue), expected \(vector.expectedValue)"
        )

        // Selection: scale 0-100 percentages to 0..<10000 bucket-units (×100). Sorted keys
        // reproduce the JS SDK's insertion-order iteration for every committed vector (all are
        // {varA, varB}; insertion order == alphabetical) — see the KEY-ORDER NOTE in the header.
        let weights = vector.buckets
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, weight: $0.value * 100) }
        let selected = BucketingManager.selectBucket(weights: weights, value: vector.expectedValue)
        let variationFailure = "variation mismatch for \(vector.description): "
            + "got \(String(describing: selected)), expected \(vector.expectedVariationId)"
        #expect(selected == vector.expectedVariationId, "\(variationFailure)")
    }
}
