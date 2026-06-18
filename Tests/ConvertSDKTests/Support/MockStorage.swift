// MockStorage.swift
// Test doubles for the two visitor-identity persistence ports — ``SecureStore`` (Keychain) and
// ``KeyValueStore`` (UserDefaults mirror) — consumed by the Story 3.1 ConvertContext visitor-
// identity suite (`ConvertContextTests.swift`). Both ports are visible to this target via the
// `@_exported import ConvertSDKCore` re-export inside `ConvertSDK`.
//
// ── Why a SEPARATE file rather than extending `MockPorts.swift` ────────────────────────────────
// `MockPorts.swift` is 395 lines; SwiftLint's `file_length` rule warns at 400 and — under the CI
// zero-warnings gate (`swiftlint --strict`, Story 1.3) — that warning escalates to an error.
// Adding these two mocks inline would push the file past 400 and break the gate. This file follows
// the codebase's OWN documented precedent: `MockClock` was likewise extracted to its sibling
// `MockClock.swift` "once its stepping API outgrew this file's 400-line lint limit" (see the
// `MockPorts.swift` header). The mocks compile into the SAME `ConvertSDKTests` target and are
// `@testable`-reachable exactly as if inlined.
//
// ── Concurrency shape (mirrors MockLogger / MockClock) ────────────────────────────────────────
// Neither port's requirements are `async` — `SecureStore.read/write/delete` are SYNCHRONOUS and
// `throws`; `KeyValueStore.string/set/removeObject` are SYNCHRONOUS and non-throwing — so an
// `actor` cannot satisfy them (actor access is async). Both ports refine `Sendable`, so each mock
// must be `Sendable`. The compiler-blessed shape on this package's macOS 12 / iOS 15 floor (where
// `Synchronization.Mutex` is unavailable and `@unchecked Sendable` is forbidden by policy) is a
// `final class` whose entire mutable state lives in ONE ``LockedBox`` cell — the exact primitive
// `MockLogger` and `MockClock` use. The single `nonisolated(unsafe)` audit surface stays confined
// to `LockedBox` (in `MockPorts.swift`); these mocks carry zero suppressions of their own.

import Foundation
import ConvertSDK

// MARK: - MockSecureStore

/// Test double for ``SecureStore`` — the Keychain-backed visitor-UUID port.
///
/// Backs an in-memory `[String: String]` map and counts reads and writes so a suite can assert
/// persistence behavior THROUGH the SDK: an explicit caller-supplied visitor ID must NOT write the
/// Keychain (``writeCallCount`` stays `0`), whereas a generated UUID must (``writeCallCount`` is
/// `1`). Construct it empty (the "no persisted ID" path → the resolver generates + persists) or
/// seeded (a pre-existing ID the resolver returns verbatim).
///
/// Shape: `final class` + ``LockedBox`` — `read`/`write`/`delete` are synchronous (`throws`),
/// which an `actor` cannot satisfy; all mutable state (the map + the two counters) sits in one
/// `LockedBox<State>` cell, mirroring ``MockLogger``'s single-`State` discipline.
final class MockSecureStore: SecureStore {
    /// The mock's mutable state in a single cell: the backing store plus the call counters, so a
    /// read and its counter bump (and a write and its counter bump) mutate atomically under one
    /// lock acquisition — a counter can never drift from the store it describes.
    private struct State {
        var storage: [String: String]
        var readCallCount = 0
        var writeCallCount = 0
        var deleteCallCount = 0
    }
    private let state: LockedBox<State>

    /// Creates the store over an optional initial map. Empty (the default) models the
    /// "nothing persisted yet" path that drives the resolver to generate + persist a fresh UUID;
    /// seed it to model a pre-existing Keychain entry the resolver should return verbatim.
    init(seeded: [String: String] = [:]) {
        self.state = LockedBox(State(storage: seeded))
    }

    /// Number of ``read(key:)`` calls observed. Read under the lock.
    var readCallCount: Int { state.withLock { $0.readCallCount } }

    /// Number of ``write(_:key:)`` calls observed — the load-bearing assertion for AC3/AC7:
    /// `0` for an explicit developer-supplied ID, `1` for a generated UUID. Read under the lock.
    var writeCallCount: Int { state.withLock { $0.writeCallCount } }

    /// Number of ``delete(key:)`` calls observed. Read under the lock.
    var deleteCallCount: Int { state.withLock { $0.deleteCallCount } }

    /// Returns the currently-stored value for `key` (without bumping any counter), or `nil`.
    func value(forKey key: String) -> String? {
        state.withLock { $0.storage[key] }
    }

    func read(key: String) throws -> String? {
        state.withLock { state in
            state.readCallCount += 1
            return state.storage[key]
        }
    }

    func write(_ value: String, key: String) throws {
        state.withLock { state in
            state.writeCallCount += 1
            state.storage[key] = value
        }
    }

    func delete(key: String) throws {
        state.withLock { state in
            state.deleteCallCount += 1
            state.storage[key] = nil
        }
    }
}

// MARK: - MockKeyValueStore

/// Test double for ``KeyValueStore`` — the lightweight `UserDefaults`-style visitor-id mirror.
///
/// Backs an in-memory `[String: String]` map and counts `set`/`removeObject` calls so a suite can
/// assert the mirror backfill the resolver performs when it generates (or Keychain-recovers) an ID.
///
/// Shape: `final class` + ``LockedBox`` — its requirements are synchronous and non-throwing, which
/// an `actor` cannot satisfy; all mutable state lives in one `LockedBox<State>` cell.
final class MockKeyValueStore: KeyValueStore {
    /// The mock's mutable state in a single cell: the backing store plus the write/remove counters,
    /// so each mutation and its counter bump happen atomically under one lock acquisition.
    private struct State {
        var storage: [String: String]
        var setCallCount = 0
        var removeCallCount = 0
    }
    private let state: LockedBox<State>

    /// Creates the store over an optional initial map. Empty (the default) models the
    /// "no mirror value yet" path; seed it to model a mirror that already holds a recovered ID.
    init(seeded: [String: String] = [:]) {
        self.state = LockedBox(State(storage: seeded))
    }

    /// Number of ``set(_:forKey:)`` calls observed. Read under the lock.
    var setCallCount: Int { state.withLock { $0.setCallCount } }

    /// Number of ``removeObject(forKey:)`` calls observed. Read under the lock.
    var removeCallCount: Int { state.withLock { $0.removeCallCount } }

    /// Returns the currently-stored value for `key` (without bumping any counter), or `nil`.
    func value(forKey key: String) -> String? {
        state.withLock { $0.storage[key] }
    }

    func string(forKey key: String) -> String? {
        state.withLock { $0.storage[key] }
    }

    func set(_ value: String, forKey key: String) {
        state.withLock { state in
            state.setCallCount += 1
            state.storage[key] = value
        }
    }

    func removeObject(forKey key: String) {
        state.withLock { state in
            state.removeCallCount += 1
            state.storage[key] = nil
        }
    }
}
