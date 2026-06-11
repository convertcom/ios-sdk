// CoordinatedFileStore.swift
// Concrete file-store adapter (Epic 2, Story 2.3 / 3): persists the cached
// configuration to disk via `NSFileCoordinator` + `FileManager`. Lives in the
// `ConvertSDK` (platform) target because it depends on Foundation file I/O; the
// pure-logic `ConvertSDKCore` must NOT import it.

import Foundation

// `NSFileCoordinator`-backed implementation of the SDK's on-disk config cache.
//
// Modeled as an `actor` so it is `Sendable` and data-race-clean under Swift 6
// strict concurrency with NO `@unchecked` suppression — the actor serializes all
// access to its file operations.
//
// `NSFileCoordinator` is the forward-compatible OS-file-lock seam (R1/NFR14): when
// the SDK later shares its cache across an App Group with an extension, coordinated
// reads/writes are already in place to arbitrate concurrent access between
// processes. Writes go through `.atomic`, so a partial/torn write can NEVER reach
// disk — a reader sees either the previous file or the fully replaced one.
public final actor CoordinatedFileStore {
    /// Creates the file store. Stateless — the actor exists purely to serialize the
    /// coordinated file operations.
    public init() {}

    /// Writes `data` to `url` atomically under file coordination, creating the parent
    /// directory (with intermediates) first if it is missing.
    ///
    /// `.atomic` guarantees no partial write is ever observable: the bytes land in a
    /// temporary file that is renamed into place, so a concurrent or crashed reader
    /// never sees a half-written config. `.forReplacing` is the correct coordinator
    /// option for an overwrite. The coordinator block is non-throwing, so the inner
    /// error is captured and rethrown outside it.
    public func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { writingURL in
            do {
                try data.write(to: writingURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
        if let coordinatorError { throw coordinatorError }
    }

    /// Reads the bytes at `url` under file coordination.
    ///
    /// A missing file makes `Data(contentsOf:)` throw, which is the intended
    /// "read of an absent cache is an error" behavior the caller treats as a cache
    /// miss. The coordinator block is non-throwing, so the inner error is captured and
    /// rethrown outside it.
    public func read(from url: URL) throws -> Data {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var result: Data?
        var readError: Error?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readingURL in
            do {
                result = try Data(contentsOf: readingURL)
            } catch {
                readError = error
            }
        }
        if let readError { throw readError }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return result
    }

    /// Removes the file at `url` if it exists, under file coordination.
    ///
    /// Coordinates the deletion via `NSFileCoordinator` (`.forDeleting`) so it shares
    /// the same OS-file-lock seam as `write`/`read` (R1/NFR14): when the cache later
    /// lives in an App Group, an extension's coordinated write can never race this
    /// removal. Total / no-throw: the inner `removeItem` stays `try?`, so a
    /// file-not-found error is swallowed and deleting an absent cache is a successful
    /// no-op. Unlike `write`/`read`, a coordination failure is also swallowed — the
    /// contract is "remove if present; never throw".
    public func delete(at url: URL) {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { deletingURL in
            try? FileManager.default.removeItem(at: deletingURL)
        }
        // coordinatorError intentionally ignored — delete is no-throw (a coordination
        // failure or a missing file is swallowed; the contract is "remove if present").
        _ = coordinatorError
    }

    /// Builds the on-disk cache path for `sdkKey` — a pure URL builder with no actor
    /// isolation and no I/O:
    /// `{applicationSupportDirectory}/com.convertexperiments.sdk/config-{key}.json`.
    ///
    /// Any `/` in the key is sanitized to `_` in the FILENAME only (filename safety;
    /// the directory segments are fixed). Per the story Dev Notes "Cache File Path
    /// Convention", Application Support is never `nil` on a supported platform, so a
    /// `nil` result is a programmer/environment error surfaced via `fatalError`.
    public static func configCacheURL(for sdkKey: String) -> URL {
        let sanitizedKey = sdkKey.replacingOccurrences(of: "/", with: "_")
        let appSupportDirs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let appSupport = appSupportDirs.first else {
            fatalError("Application Support directory is unavailable on this platform")
        }
        return appSupport
            .appendingPathComponent("com.convertexperiments.sdk", isDirectory: true)
            .appendingPathComponent("config-\(sanitizedKey).json")
    }
}
