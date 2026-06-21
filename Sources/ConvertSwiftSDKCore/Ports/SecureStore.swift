// SecureStore.swift
// Port: secure key/value storage for the visitor UUID.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.
//
// This is a protocol only. The concrete adapter (a later story) backs it with the
// Security framework (Keychain), but this declaration imports Foundation ONLY — the
// pure-logic core never links a platform security framework.

import Foundation

/// Secure storage for the visitor UUID, backed by the Keychain in its concrete adapter.
///
/// Pure logic depends only on this string-keyed read/write/delete contract. The adapter
/// (a later story) provides the Keychain-backed implementation; this port deliberately
/// imports Foundation only and never references the Security framework.
public protocol SecureStore: Sendable {
    /// Returns the stored value for the given key, or `nil` when no entry exists.
    func read(key: String) throws -> String?

    /// Stores the given value under the given key, replacing any existing entry.
    func write(_ value: String, key: String) throws

    /// Removes the entry for the given key, if one exists.
    func delete(key: String) throws
}
