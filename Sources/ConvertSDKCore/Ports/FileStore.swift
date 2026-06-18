// FileStore.swift
// Port: atomic file I/O.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Atomic file I/O for the configuration cache and the decision store.
///
/// The concrete adapter (Epic 2) performs atomic reads and writes so partially written
/// data is never observed by a reader. Pure logic depends only on this read/write contract
/// and stays unaware of the underlying filesystem details.
public protocol FileStore: Sendable {
    /// Reads the entire contents of the file at the given URL.
    func read(from url: URL) async throws -> Data

    /// Writes the given data to the URL atomically, replacing any existing file.
    func write(_ data: Data, to url: URL) async throws
}
