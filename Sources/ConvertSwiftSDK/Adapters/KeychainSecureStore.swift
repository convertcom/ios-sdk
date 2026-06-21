// KeychainSecureStore.swift
// Concrete secure-store adapter (Epic 3, Story 3.1): persists the visitor UUID to the
// Keychain via the Security framework. Lives in the `ConvertSwiftSDK` (platform) target
// because it links Security; the pure-logic `ConvertSwiftSDKCore` must NOT import it — the
// `SecureStore` port it conforms to imports Foundation only.

import Foundation
import Security

/// Keychain-backed implementation of the SDK's ``SecureStore`` port.
///
/// Stores each value as a `kSecClassGenericPassword` item scoped by
/// `kSecAttrService` (the injected `service`) and `kSecAttrAccount` (the key). The
/// service is injectable so tests can use an isolated service string and never collide
/// with a real SDK item or with each other.
///
/// New items are written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: the
/// visitor id must be readable by background refreshes after the first unlock following
/// a reboot, and `…ThisDeviceOnly` keeps the value off iCloud Keychain so it never
/// syncs to other devices.
///
/// Resilience contract: every method handles all `OSStatus` outcomes internally and
/// NEVER throws out — a Keychain that is unavailable in the current environment (e.g.
/// an entitlement-less CI runner returning `errSecMissingEntitlement`) degrades to a
/// logged warning and a graceful miss (`read` → `nil`), not a crash or a thrown error.
/// The methods are declared `throws` to satisfy the port; a `throws` func that never
/// throws is legal and keeps the contract "best-effort, never propagate a Keychain
/// failure to the caller".
///
/// `Sendable` with NO `@unchecked` and NO `nonisolated(unsafe)`: both stored properties
/// are immutable `let`s of `Sendable` types — `String` and the `any Logger` existential
/// (the ``Logger`` port refines `Sendable`) — so the compiler proves data-race safety
/// with no suppression.
public final class KeychainSecureStore: SecureStore {
    /// The `kSecAttrService` every item is scoped under. Immutable and `Sendable`.
    private let service: String

    /// Sink for the best-effort warnings/debug lines this adapter emits when a Keychain
    /// operation fails. The ``Logger`` port refines `Sendable`, so this `let` keeps the
    /// class `Sendable` with no suppression.
    private let logger: Logger

    /// Creates the store. `service` defaults to the SDK's shared service string;
    /// inject a unique value to isolate items (tests do this per case). `logger`
    /// defaults to a ``NoopLogger`` so the adapter is usable with no destination.
    public init(service: String = "com.convert.sdk", logger: Logger = NoopLogger()) {
        self.service = service
        self.logger = logger
    }

    /// Returns the stored value for `key`, or `nil` on any miss-or-failure.
    ///
    /// `errSecItemNotFound` is an expected miss (logged at `.debug`, never `.warn`); any
    /// other non-success `OSStatus` is an unexpected failure that still degrades to
    /// `nil` (logged at `.warn`). Stored bytes that are not valid UTF-8 — unreachable
    /// through this `String`-typed adapter but guarded for defense in depth — also yield
    /// a `.warn` and `nil`. An empty string is treated as a miss (`nil`) so a blank
    /// value never masquerades as a stored id. Declared `throws` to satisfy the port,
    /// but never actually throws: all outcomes resolve to `nil`.
    public func read(key: String) throws -> String? {
        var query: [String: Any] = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            logger.log(
                level: .debug,
                type: "KeychainSecureStore",
                method: "read",
                message: "item not found (errSecItemNotFound) — treating as miss"
            )
            return nil
        }

        guard status == errSecSuccess else {
            logger.log(
                level: .warn,
                type: "KeychainSecureStore",
                method: "read",
                message: "unexpected OSStatus \(status)"
            )
            return nil
        }

        guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
            logger.log(
                level: .warn,
                type: "KeychainSecureStore",
                method: "read",
                message: "stored data is not valid UTF-8"
            )
            return nil
        }

        // An empty stored value is treated as a miss so a blank entry never reads back
        // as a "present" id.
        return str.isEmpty ? nil : str
    }

    /// Stores `value` under `key`, replacing any existing entry.
    ///
    /// Tries `SecItemAdd` first; on `errSecDuplicateItem` falls back to `SecItemUpdate`
    /// of the existing item's data. Any failing `OSStatus` (a failed add that is not a
    /// duplicate, or a failed update) is logged at `.warn` and swallowed — write is
    /// best-effort and NEVER throws, so an entitlement-less environment logs a warning
    /// and moves on rather than crashing (the round-trip then simply does not persist,
    /// which the tests' environment probe tolerates). Declared `throws` to satisfy the
    /// port; never actually throws.
    public func write(_ value: String, key: String) throws {
        // A `String` always encodes to UTF-8, so this guard cannot fail in practice; it
        // exists so the failure is a no-op rather than a force-unwrap.
        guard let data = value.data(using: .utf8) else { return }

        let base = baseQuery(forKey: key)

        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)

        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                base as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus != errSecSuccess {
                logger.log(
                    level: .warn,
                    type: "KeychainSecureStore",
                    method: "write",
                    message: "update failed OSStatus \(updateStatus)"
                )
            }
        } else if addStatus != errSecSuccess {
            logger.log(
                level: .warn,
                type: "KeychainSecureStore",
                method: "write",
                message: "add failed OSStatus \(addStatus)"
            )
        }
    }

    /// Removes the entry for `key`, if one exists.
    ///
    /// Both `errSecSuccess` (deleted) and `errSecItemNotFound` (already absent) are
    /// successful no-ops. Any other `OSStatus` is logged at `.debug` and swallowed —
    /// delete is best-effort and NEVER throws. Declared `throws` to satisfy the port;
    /// never actually throws.
    public func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)

        if status != errSecSuccess && status != errSecItemNotFound {
            logger.log(
                level: .debug,
                type: "KeychainSecureStore",
                method: "delete",
                message: "delete returned OSStatus \(status)"
            )
        }
    }

    /// The shared item-identity query for `key`: a generic-password item scoped by this
    /// store's `service` and the given account. Returned as `[String: Any]` so each call
    /// site casts it to `CFDictionary` (and adds the operation-specific attributes) at
    /// the `SecItem*` call. Centralized so the class/service/account triple is written
    /// once, not restated across read/write/delete.
    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
