// UserDefaultsKeyValueStore.swift
// Concrete key/value-store adapter (Epic 3, Story 3.1): mirrors the visitor-id (and
// other lightweight string values) into `UserDefaults`. Lives in the `ConvertSwiftSDK`
// (platform) target because it depends on a Foundation persistence type; the
// pure-logic `ConvertSwiftSDKCore` must NOT import it.

import Foundation

/// `UserDefaults`-backed implementation of the SDK's lightweight key/value store.
///
/// Each method is a thin pass-through to the injected `UserDefaults`. The backing
/// store is injectable (defaulting to `.standard`) so callers — and tests — can point
/// it at an isolated `UserDefaults(suiteName:)` domain rather than polluting the shared
/// standard defaults.
///
/// `Sendable` with NO `@unchecked`: `KeyValueStore` refines `Sendable`, so this
/// adapter must be `Sendable` too. `UserDefaults` is documented thread-safe (Apple's
/// reference: "UserDefaults … is thread-safe"), but it is an `NSObject` subclass that
/// is NOT formally `Sendable` in the SDK's Foundation overlay, so a plain `let` does
/// not auto-conform this class. The sanctioned last-resort form — the SAME single
/// annotation `LockedBox` and `ConvertSwiftSDK.shared` use, and the architecture's accepted
/// alternative to the banned `@unchecked` — is `nonisolated(unsafe)` on the one
/// immutable stored property. It is sound here because `defaults` is assigned once at
/// init and never mutated, and `UserDefaults` serializes its own concurrent access; the
/// annotation merely tells the Swift 6 compiler this single reference is hand-audited.
public final class UserDefaultsKeyValueStore: KeyValueStore {
    /// The backing defaults database. `nonisolated(unsafe)` because `UserDefaults` is
    /// thread-safe but not formally `Sendable` in the overlay; the reference is an
    /// immutable `let` assigned once at init, so this single audited annotation lets the
    /// class claim `Sendable` without `@unchecked`. (A plain `let` does not compile —
    /// `UserDefaults` is non-`Sendable` — so this is the minimal correct escape.)
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates the store over `defaults`, defaulting to `UserDefaults.standard`.
    /// Inject a `UserDefaults(suiteName:)` to keep writes out of the shared domain.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns the stored string for `key`, or `nil` when absent — a direct
    /// pass-through to `UserDefaults.string(forKey:)`.
    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    /// Stores `value` under `key`, overwriting any existing entry — a direct
    /// pass-through to `UserDefaults.set(_:forKey:)`.
    public func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    /// Removes the entry for `key`, if any — a direct pass-through to
    /// `UserDefaults.removeObject(forKey:)`.
    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}
