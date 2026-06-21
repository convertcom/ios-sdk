// CoordinatedFileEventQueueStore.swift
// Concrete `EventQueueStore` adapter (Epic 5, Story 5.2): persists the pending
// tracking-event queue to disk via the owned `CoordinatedFileStore`
// (`NSFileCoordinator` + atomic writes), adding the Codable layer + corruption
// recovery on top. Lives in the `ConvertSwiftSDK` (platform) target because it depends
// on Foundation file I/O via `CoordinatedFileStore`; the pure-logic
// `ConvertSwiftSDKCore` must NOT import it.

import Foundation
import ConvertSwiftSDKCore

/// Durable, coordinated persistence for the pending tracking-event queue — the production
/// ``EventQueueStore`` (FR51 / NFR13).
///
/// It is a thin Codable wrapper that DELEGATES every raw file operation to an owned
/// ``CoordinatedFileStore`` (itself an `actor`), so the actual disk I/O — and the single
/// `NSFileCoordinator` usage — lives in exactly ONE place. This adapter therefore neither
/// imports nor references `NSFileCoordinator` directly; the atomic-write semantics and the
/// intermediate-directory creation both come for free from the delegate.
///
/// ── Why `final actor` (not `@unchecked Sendable` class) ───────────────────────────────────
/// Modeled as a `public final actor` so it is `Sendable` and data-race-clean under Swift 6
/// strict concurrency with NO `@unchecked` suppression — the actor serializes all in-process
/// access to its operations. The delegated ``CoordinatedFileStore`` wraps `NSFileCoordinator`,
/// the forward-compatible OS-file-lock seam (R1 / NFR14): when the queue later lives in a
/// shared App Group (so an extension can flush events too), coordinated reads/writes already
/// arbitrate concurrent access between processes. The actor handles the in-process seam; the
/// coordinator handles the cross-process one.
///
/// ── Why `.useDefaultKeys` (AR13) ──────────────────────────────────────────────────────────
/// The ``JSONEncoder`` is pinned to `.useDefaultKeys` and NEVER `.convertToSnakeCase`:
/// ``TrackingEvent`` declares explicit camelCase `CodingKeys`, so snake_case keys must never
/// leak onto disk (or, after a flush, onto the wire). The decoder likewise uses default keys —
/// the persisted file round-trips byte-for-byte with the wire payload.
///
/// ── Why corruption degrades to `[]` and NEVER throws (FR51 / NFR13) ────────────────────────
/// A file that exists but fails to decode (bad/garbled bytes) is discarded — ``load()`` logs a
/// WARN through the ``Logger`` port, deletes the file, and returns `[]`. The SDK degrades to an
/// empty queue rather than crashing on bad bytes. A MISSING file (normal first launch, or the
/// state right after a successful flush cleared it) is distinct: it returns `[]` SILENTLY, with
/// NO warn — it is not an error, just an empty queue.
public final actor CoordinatedFileEventQueueStore: EventQueueStore {
    /// The on-disk location of the queue file. Supplied at construction (the default production
    /// path comes from ``queueFileURL()``), so tests can point it at an isolated temp URL.
    private let fileURL: URL

    /// The structured logging sink the corruption-recovery WARN is emitted through. The WARN
    /// MUST go through this port (never `print`) so the log line has one owner and format.
    private let logger: any Logger

    /// The coordinated, atomic file store every raw file operation delegates to. Owning it as a
    /// `let` keeps this adapter all-`let` and `Sendable` with no suppression; because it is an
    /// `actor`, the delegated I/O hops onto its executor — off this adapter's caller — and keeps
    /// `NSFileCoordinator` confined to that one type.
    private let coordinated = CoordinatedFileStore()

    /// Encodes the queue with the DEFAULT key strategy (AR13) — explicitly NOT
    /// `.convertToSnakeCase`, so the camelCase wire spellings on ``TrackingEvent`` are preserved
    /// on disk and survive a later flush onto the wire unchanged.
    private let encoder: JSONEncoder

    /// Decodes the persisted queue back into `[TrackingEvent]`. ``TrackingEvent/init(from:)``
    /// re-forces `enrichData`/`source`, so a decode is wire-safe regardless of the file contents.
    private let decoder: JSONDecoder

    /// Creates the queue store over `fileURL`, emitting any corruption WARN through `logger`.
    public init(fileURL: URL, logger: any Logger) {
        self.fileURL = fileURL
        self.logger = logger
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// Loads the persisted queue, returning `[]` when nothing usable is stored.
    ///
    /// Three outcomes, by what the delegated read surfaces:
    ///   * Bytes that decode → the decoded `[TrackingEvent]`.
    ///   * MISSING file → `CoordinatedFileStore.read` rethrows the `CocoaError(.fileReadNoSuchFile)`
    ///     that `Data(contentsOf:)` throws for an absent file; caught here and returned as `[]`
    ///     SILENTLY (first launch / post-flush is not an error — NO warn).
    ///   * Present-but-undecodable file → caught by the generic branch: WARN through the logger,
    ///     delete the file (re-initialize), return `[]`. NEVER rethrown on corruption (FR51 / NFR13).
    public func load() async throws -> [TrackingEvent] {
        do {
            let data = try await coordinated.read(from: fileURL)
            return try decoder.decode([TrackingEvent].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            logger.log(
                level: .warn,
                type: "CoordinatedFileEventQueueStore",
                method: "load",
                message: "event queue file corrupt, discarding and re-initializing: "
                    + error.localizedDescription
            )
            await coordinated.delete(at: fileURL)
            return []
        }
    }

    /// Persists `events` atomically, replacing any prior contents.
    ///
    /// An empty array is equivalent to ``clear()`` — no `[]` JSON file is left behind. Otherwise
    /// the encoded bytes land via the delegate's `.atomic` write (no torn write is ever
    /// observable) and the parent directory is created with intermediates first if missing.
    public func persist(_ events: [TrackingEvent]) async throws {
        if events.isEmpty {
            try await clear()
            return
        }
        let data = try encoder.encode(events)
        try await coordinated.write(data, to: fileURL)
    }

    /// Removes the persisted queue file entirely (equivalent to `persist([])`).
    ///
    /// Delegates to the no-throw ``CoordinatedFileStore/delete(at:)``: erasing an already-absent
    /// queue is a successful no-op. The port marks this `async throws`, but the delegate never
    /// throws — so in practice this method simply never does either.
    public func clear() async throws {
        await coordinated.delete(at: fileURL)
    }

    // MARK: - Background-upload in-flight marker (Story 5.3 / F-052 — cross-path exactly-once)

    /// The sibling marker file whose PRESENCE means "a durable background `URLSession` upload of the
    /// queue file is outstanding". Derived from ``fileURL`` (`event-queue.json` → `event-queue.uploading`)
    /// so a test pointing the store at an isolated temp URL gets a co-located marker automatically, and
    /// the marker rides the SAME coordinated/atomic seam (``CoordinatedFileStore``) as the queue file.
    private var markerFileURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("uploading")
    }

    /// Writes the in-flight marker (a one-byte sentinel) through the coordinated, atomic delegate —
    /// claiming the queue file for the background-upload path. `BackgroundSessionManager.enqueueUpload`
    /// calls this before submitting the upload task.
    public func markBackgroundUploadInFlight() async throws {
        try await coordinated.write(Data([1]), to: markerFileURL)
    }

    /// Deletes the in-flight marker via the no-throw coordinated delete — releasing the queue file back
    /// to the foreground-recovery / cold-start paths. `BackgroundUploadDelegate.reconcile` calls this on
    /// every outcome.
    public func clearBackgroundUploadInFlight() async throws {
        await coordinated.delete(at: markerFileURL)
    }

    /// Whether the marker file exists. A MISSING marker rethrows `CocoaError(.fileReadNoSuchFile)` from
    /// the delegate's `read`, caught here as `false` (the common case); any OTHER read error also
    /// degrades to `false` (see the port doc — never stall delivery on an ambiguous marker read).
    public func isBackgroundUploadInFlight() async throws -> Bool {
        do {
            _ = try await coordinated.read(from: markerFileURL)
            return true
        } catch {
            return false
        }
    }

    /// Builds the production queue path — a pure URL builder with no actor isolation and no I/O:
    /// `{applicationSupportDirectory}/com.convertexperiments.sdk/event-queue.json`.
    ///
    /// Mirrors ``CoordinatedFileStore/configCacheURL(for:)`` exactly: same Application Support
    /// base, same `com.convertexperiments.sdk` namespace segment, fixed `event-queue.json`
    /// filename. Application Support is never `nil` on a supported platform, so a `nil` result is
    /// a programmer/environment error surfaced via `fatalError`.
    public static func queueFileURL() -> URL {
        let appSupportDirs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let appSupport = appSupportDirs.first else {
            fatalError("Application Support directory is unavailable on this platform")
        }
        return appSupport
            .appendingPathComponent("com.convertexperiments.sdk", isDirectory: true)
            .appendingPathComponent("event-queue.json")
    }
}
