// Defaults.swift
// Load-bearing default constants for the Convert iOS SDK.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// Load-bearing, **JS-SDK-parity** default constants.
///
/// These values mirror the Convert JavaScript SDK exactly and drive cross-SDK bucketing
/// agreement — they are not free to retune:
/// - ``hashSeed`` — the MurmurHash3 seed (`UInt32`) used when hashing the bucketing key.
/// - ``maxTraffic`` — the inclusive upper bound of the bucket range (`0..<maxTraffic`).
/// - ``maxHash`` — `2^32` (`UInt64`), the hash-space size used to project a hash onto the
///   bucket range without overflowing 32-bit arithmetic.
///
/// Names are `lowerCamelCase` (Swift convention), not the JS `UPPER_SNAKE_CASE` source form.
public enum Defaults {
    /// MurmurHash3 seed. `UInt32` width is mandatory for bucketing parity with the JS SDK.
    public static let hashSeed: UInt32 = 9_999

    /// Inclusive upper bound of the bucket range (`0..<maxTraffic`).
    public static let maxTraffic = 10_000

    /// Hash-space size (`2^32`). `UInt64` width is mandatory to hold `4_294_967_296`
    /// and to keep the bucket projection arithmetic from overflowing.
    public static let maxHash: UInt64 = 4_294_967_296

    /// Number of queued events flushed per release batch.
    public static let batchSize = 10

    /// Interval, in milliseconds, between event-queue release attempts.
    public static let releaseIntervalMs = 1_000

    /// Interval, in milliseconds, between remote configuration refreshes.
    public static let dataRefreshIntervalMs = 300_000

    /// Per-request timeout (seconds) for foreground HTTP. FR45: a bounded value, NOT the
    /// 7-day URLSession default.
    public static let requestTimeoutSeconds: TimeInterval = 30

    /// Whole-resource timeout (seconds) for foreground HTTP. FR45: bounded with generous
    /// headroom for large configs on slow links (5 min), NOT the 7-day default.
    public static let resourceTimeoutSeconds: TimeInterval = 300

    /// LRU cap for the in-memory visitor decision cache (NFR4) — mirrors JS LOCAL_STORE_LIMIT.
    public static let localStoreLimit = 10_000
}
