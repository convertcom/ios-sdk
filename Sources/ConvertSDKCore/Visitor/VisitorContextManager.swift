// VisitorContextManager.swift
// Resolves the effective visitor ID for a context: honour an explicit caller-supplied ID, else
// read it back from persistent storage (Keychain, then the key/value mirror), else generate and
// persist a fresh one. Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Pure resolution of "which visitor ID does this context use", with a deterministic precedence
/// over the two persistence ports. A stateless `enum` (no cases, only a static function) so it is
/// trivially `Sendable` with zero stored state and zero suppressions — all inputs are injected.
///
/// ── Precedence (load-bearing; bucketing parity depends on byte-for-byte stability) ───────────
///   1. An explicit `provided` ID that is non-`nil` AND non-empty is returned **verbatim** —
///      never trimmed, never case-folded, and with NO store access at all. Any normalisation here
///      would change the bucket a visitor lands in versus the other SDKs, so the raw bytes are
///      sacrosanct (story Dev Notes).
///   2. Otherwise the canonical Keychain entry is read. A non-empty value is returned as-is with
///      no re-write.
///   3. A Keychain MISS (`nil`) OR a corrupted/empty (`""`) entry both fall through to the
///      key/value mirror. A present mirror value is returned AND backfilled into the Keychain so
///      the two stores re-converge.
///   4. With neither store holding a value, a fresh `UUID().uuidString` is generated, written to
///      BOTH stores, an `[INFO]` line is logged, and the UUID is returned.
///   5. If the Keychain read THROWS, the error is logged at `[WARN]`, NEVER rethrown, and the
///      flow falls back to generating a fresh UUID — a storage fault must degrade gracefully, not
///      surface to the caller.
///
/// `package` (not `internal` or `public`) because the resolver lives in ``ConvertSDKCore`` but its
/// sole caller is ``ConvertSDK/createContext(visitorId:attributes:)`` in the SEPARATE `ConvertSDK`
/// target of the SAME package. `package` is the precise access level for a symbol shared across
/// targets within one package WITHOUT exposing it to SDK consumers: an `internal` resolver could not
/// cross the target boundary, while `public` would leak it into the consumer ABI through the
/// `@_exported import ConvertSDKCore` re-export. The architecture mandates the public surface be only
/// `ConvertSDK`/`ConvertContext`/`ConvertConfiguration`/model-DTOs — everything else is
/// internal/package. `StorageKeys` stays `internal`: it appears only inside this method's body (never
/// in its signature), so it never crosses the target boundary.
package enum VisitorContextManager {
    /// Returns the effective visitor ID per the precedence documented on the type. Total — it
    /// always returns a `String` and never throws; every storage write uses `try?` so a Keychain
    /// failure on the write path is swallowed exactly like a failure on the read path.
    package static func resolveVisitorId(
        provided: String?,
        secureStore: SecureStore,
        keyValueStore: KeyValueStore,
        logger: Logger
    ) -> String {
        // 1. Explicit ID wins outright — returned verbatim with zero store access.
        if let provided, !provided.isEmpty {
            return provided
        }

        do {
            let stored = try secureStore.read(key: StorageKeys.visitorId)
            // 2. A non-empty Keychain value is authoritative — return it untouched.
            if let stored, !stored.isEmpty {
                return stored
            }
            // 3./4. Keychain miss or corrupted-empty entry: fall through to the mirror, then
            // generate. The empty-string case is deliberately treated identically to a `nil`
            // miss (no throw, no WARN) — it is data corruption, not a storage fault.
            return resolveFromMirrorOrGenerate(
                secureStore: secureStore,
                keyValueStore: keyValueStore,
                logger: logger
            )
        } catch {
            // 5. The Keychain read FAILED. Log at WARN, never rethrow, and degrade to a freshly
            // generated UUID. Writes inside the generator use `try?`, so a second fault on the
            // write path is swallowed too.
            logger.log(
                level: .warn,
                type: "VisitorContextManager",
                method: "resolveVisitorId",
                message: "storage error — \(error.localizedDescription)"
            )
            return generateAndPersist(
                secureStore: secureStore,
                keyValueStore: keyValueStore,
                logger: logger
            )
        }
    }

    /// Keychain held nothing usable: try the key/value mirror, backfilling the Keychain when the
    /// mirror has a value, otherwise generate a brand-new ID. Split out so both the normal miss
    /// path and the corrupted-empty path share one body (no duplication, one place to evolve).
    private static func resolveFromMirrorOrGenerate(
        secureStore: SecureStore,
        keyValueStore: KeyValueStore,
        logger: Logger
    ) -> String {
        if let mirrored = keyValueStore.string(forKey: StorageKeys.visitorIdMirror), !mirrored.isEmpty {
            // Mirror hit: re-converge the stores by backfilling the Keychain (best-effort), then
            // return the recovered ID. No INFO log — this is a recovery, not a first generation.
            try? secureStore.write(mirrored, key: StorageKeys.visitorId)
            return mirrored
        }
        return generateAndPersist(
            secureStore: secureStore,
            keyValueStore: keyValueStore,
            logger: logger
        )
    }

    /// Generates a fresh `UUID().uuidString`, persists it to BOTH stores (Keychain write is
    /// best-effort via `try?`; the mirror write cannot throw), logs the first-generation INFO
    /// line, and returns the new ID.
    private static func generateAndPersist(
        secureStore: SecureStore,
        keyValueStore: KeyValueStore,
        logger: Logger
    ) -> String {
        let uuid = UUID().uuidString
        try? secureStore.write(uuid, key: StorageKeys.visitorId)
        keyValueStore.set(uuid, forKey: StorageKeys.visitorIdMirror)
        logger.log(
            level: .info,
            type: "VisitorContextManager",
            method: "resolveVisitorId",
            message: "no persisted visitor ID found, generating new UUID"
        )
        return uuid
    }
}
