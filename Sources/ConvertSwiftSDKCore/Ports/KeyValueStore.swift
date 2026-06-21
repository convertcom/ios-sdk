// KeyValueStore.swift
// Port: lightweight key/value storage.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// Lightweight key/value storage for the feature-flags cache and the visitor-id mirror.
///
/// Modeled on a `UserDefaults`-style interface; the concrete adapter (Epic 2) provides the
/// backing store. Pure logic reads and writes string values by key without knowing where
/// they are persisted.
public protocol KeyValueStore: Sendable {
    /// Returns the stored string for the given key, or `nil` when absent.
    func string(forKey key: String) -> String?

    /// Stores the given string under the given key.
    func set(_ value: String, forKey key: String)

    /// Removes the value stored for the given key, if any.
    func removeObject(forKey key: String)
}
