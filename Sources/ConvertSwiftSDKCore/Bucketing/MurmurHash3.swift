// Sources/ConvertSwiftSDKCore/Bucketing/MurmurHash3.swift
// MurmurHash3 x86 32-bit (MurmurHash3_x86_32).
//
// Algorithm by Austin Appleby — released to the public domain (no rights reserved).
// This is a from-scratch Swift port; the constants, block/tail handling, and fmix32
// finalization mirror the canonical reference so the output is byte-for-byte identical
// to the Convert JavaScript SDK's `murmurhash@2.0.1` `v3` (= murmurhash3_x86_32),
// which is authoritative for cross-SDK bucketing parity.
//
// CORRECTNESS NOTE — wrapping arithmetic: MurmurHash3 is defined in terms of C's
// modulo-2^32 wrapping arithmetic. Swift `UInt32` `*`/`+`/`<<` TRAP on overflow rather
// than wrapping, so every overflow-capable operation below uses the wrapping operators
// `&*`, `&+`, and `&<<`. Plain operators would crash in debug builds and break parity.

import Foundation

/// Stateless namespace for the MurmurHash3 x86 32-bit hash used by deterministic bucketing.
internal enum MurmurHash3 {
    // The two body-mix constants `c1`/`c2` are part of the published algorithm. Their short,
    // canonical names (along with `k1`/`h1` below) are kept verbatim from the reference;
    // they fall under SwiftLint's `identifier_name` minimum length, so the rule is locally
    // relaxed for this file's algorithm-internal names only.
    // swiftlint:disable identifier_name
    private static let c1: UInt32 = 0xcc9e_2d51
    private static let c2: UInt32 = 0x1b87_3593

    /// Computes the 32-bit MurmurHash3 (x86 variant) of `data` with the given `seed`.
    ///
    /// - Parameters:
    ///   - data: The bytes to hash (e.g. `Array(someString.utf8)`).
    ///   - seed: The initial hash state. Must match the seed used by other SDKs for parity.
    /// - Returns: The 32-bit hash as a `UInt32`.
    static func hash(_ data: [UInt8], seed: UInt32) -> UInt32 {
        var h1 = seed
        let nblocks = data.count / 4

        // Body: consume the input four bytes at a time as little-endian 32-bit blocks.
        for block in 0..<nblocks {
            let base = block * 4
            var k1 = UInt32(data[base])
                | (UInt32(data[base + 1]) << 8)
                | (UInt32(data[base + 2]) << 16)
                | (UInt32(data[base + 3]) << 24)
            k1 = k1 &* c1
            k1 = (k1 &<< 15) | (k1 >> 17)
            k1 = k1 &* c2
            h1 ^= k1
            h1 = (h1 &<< 13) | (h1 >> 19)
            h1 = h1 &* 5 &+ 0xe654_6b64
        }

        // Tail: fold in the trailing 1–3 bytes that did not fill a full block.
        let tailStart = nblocks * 4
        let tailCount = data.count - tailStart
        var k1: UInt32 = 0
        switch tailCount {
        case 3:
            k1 ^= UInt32(data[tailStart + 2]) << 16
            fallthrough
        case 2:
            k1 ^= UInt32(data[tailStart + 1]) << 8
            fallthrough
        case 1:
            k1 ^= UInt32(data[tailStart])
            k1 = k1 &* c1
            k1 = (k1 &<< 15) | (k1 >> 17)
            k1 = k1 &* c2
            h1 ^= k1
        default:
            break
        }

        // Finalization: mix in the length, then avalanche the bits via fmix32.
        h1 ^= UInt32(data.count)
        h1 = fmix32(h1)
        return h1
    }

    /// Final avalanche mix (`fmix32`) — forces every input bit to affect the output.
    private static func fmix32(_ value: UInt32) -> UInt32 {
        var h = value
        h ^= h >> 16
        h = h &* 0x85eb_ca6b
        h ^= h >> 13
        h = h &* 0xc2b2_ae35
        h ^= h >> 16
        return h
    }
    // swiftlint:enable identifier_name
}
