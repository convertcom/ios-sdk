// Tests/ConvertSDKCoreTests/Bucketing/MurmurHash3Tests.swift
import Testing
@testable import ConvertSDKCore

@Suite("MurmurHash3")
struct MurmurHash3Tests {
    /// One cross-SDK golden vector. A named struct (not a 3-member tuple) so the
    /// `large_tuple` lint rule (max 2 members) stays satisfied, mirroring the
    /// `ManagerHarness`/`VariationSpec` precedents in this test target. Non-private
    /// because the `@Test`-discovered `golden(_:)` and its `arguments:` source `cases`
    /// reference it. `Sendable` so it can be passed through swift-testing's `arguments:`.
    struct GoldenVector: Sendable {
        let input: String
        let seed: UInt32
        let expected: UInt32
    }

    // One parameterized body covers all four cross-SDK golden vectors instead of four
    // near-identical assertion methods — keeps the new-duplicated-lines density under
    // the SonarQube gate. These golden values were computed from the published
    // `murmurhash@2.0.1` npm package (the Convert JS SDK's `v3` = murmurhash3_x86_32)
    // and are authoritative for cross-SDK bucketing parity.
    static let cases: [GoldenVector] = [
        GoldenVector(input: "", seed: 0, expected: 0),
        GoldenVector(input: "", seed: 9_999, expected: 3_523_940_263),
        GoldenVector(input: "hello", seed: 0, expected: 613_153_351),
        GoldenVector(input: "hello", seed: 9_999, expected: 198_804_431)
    ]

    @Test("murmurhash3_x86_32 matches the JS SDK golden vectors", arguments: cases)
    func golden(_ vector: GoldenVector) {
        let actual = MurmurHash3.hash(Array(vector.input.utf8), seed: vector.seed)
        #expect(
            actual == vector.expected,
            "hash(\"\(vector.input)\", seed: \(vector.seed)) = \(actual), expected \(vector.expected)"
        )
    }

    /// AC1: hashing the empty string with seed 0 yields the known empty-string hash (0).
    /// Mirrors the acceptance-criterion wording precisely; the seed-0 empty case is also
    /// covered by the first parameterized row above.
    @Test("AC1 — empty string with seed 0 hashes to 0")
    func emptyStringSeedZero() {
        #expect(MurmurHash3.hash(Array("".utf8), seed: 0) == 0)
    }
}
