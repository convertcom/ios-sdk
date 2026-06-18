// EphemeralFileStore.swift
// An in-memory, process-lifetime `FileStore` implementation.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// A ``FileStore`` that keeps written bytes only in memory for the process lifetime.
///
/// The production default for components that REQUIRE a non-`nil` ``FileStore`` but for which no
/// on-disk adapter is wired yet — currently the canonical ``DecisionStore`` the public
/// ``ConvertSDK`` initializers build before the on-disk persistence wiring lands (a later story).
/// It mirrors ``NoopLogger``: a stand-in default so a required port is always satisfiable. The
/// real coordinated on-disk store is injected by that later wiring; until then a default-built
/// ``DecisionStore`` persists to this in-memory map, which is safe because nothing currently
/// invokes its persistence path on the default store.
///
/// `read(from:)` throws `CocoaError(.fileReadNoSuchFile)` for an absent URL — the same
/// missing-file signal the on-disk adapters emit, so ``DecisionStore/loadFromDisk()`` degrades
/// to an empty store identically against either backing.
///
/// An `actor` so its in-memory map is data-race-clean under Swift 6 strict concurrency with NO
/// `Sendable` suppression — the same shape every other `async` port adapter uses.
public actor EphemeralFileStore: FileStore {
    /// In-memory backing, keyed on the URL's `absoluteString`.
    private var files: [String: Data] = [:]

    /// Creates an empty in-memory file store.
    public init() {}

    /// Returns the bytes previously written to `url`, or throws `CocoaError(.fileReadNoSuchFile)`
    /// if none — matching the on-disk adapters' missing-file signal.
    public func read(from url: URL) async throws -> Data {
        guard let data = files[url.absoluteString] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }

    /// Stores `data` in memory under `url`, replacing any prior value.
    public func write(_ data: Data, to url: URL) async throws {
        files[url.absoluteString] = data
    }
}
