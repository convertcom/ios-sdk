// Tests/ConvertSDKCoreTests/Bucketing/MurmurHash3Tests.swift
import Testing
@testable import ConvertSDKCore

@Suite("MurmurHash3")
struct MurmurHash3Tests {
    // One parameterized body covers all four cross-SDK golden vectors instead of four
    // near-identical assertion methods — keeps the new-duplicated-lines density under
    // the SonarQube gate. The explicit `[(String, UInt32, UInt32)]` element type keeps
    // the type-checker off the "expression too complex" path. These golden values were
    // computed from the published `murmurhash@2.0.1` npm package (the Convert JS SDK's
    // `v3` = murmurhash3_x86_32) and are authoritative for cross-SDK bucketing parity.
    static let cases: [(input: String, seed: UInt32, expected: UInt32)] = [
        ("", 0, 0),
        ("", 9_999, 3_523_940_263),
        ("hello", 0, 613_153_351),
        ("hello", 9_999, 198_804_431)
    ]

    @Test("murmurhash3_x86_32 matches the JS SDK golden vectors", arguments: cases)
    func golden(input: String, seed: UInt32, expected: UInt32) {
        let actual = MurmurHash3.hash(Array(input.utf8), seed: seed)
        #expect(actual == expected, "hash(\"\(input)\", seed: \(seed)) = \(actual), expected \(expected)")
    }

    /// AC1: hashing the empty string with seed 0 yields the known empty-string hash (0).
    /// Mirrors the acceptance-criterion wording precisely; the seed-0 empty case is also
    /// covered by the first parameterized row above.
    @Test("AC1 — empty string with seed 0 hashes to 0")
    func emptyStringSeedZero() {
        #expect(MurmurHash3.hash(Array("".utf8), seed: 0) == 0)
    }
}
