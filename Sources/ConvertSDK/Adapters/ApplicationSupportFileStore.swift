// ApplicationSupportFileStore.swift
// Durable async file-store adapter (Epic 3, Story 3.4 / FS-1): the production
// `FileStore` backing `DecisionStore` cross-launch persistence. Lives in the
// `ConvertSDK` (platform) target because it depends on Foundation file I/O via
// `CoordinatedFileStore`; the pure-logic `ConvertSDKCore` must NOT import it.

import Foundation

/// An async ``FileStore`` over durable on-disk storage, backed by ``CoordinatedFileStore``
/// (`NSFileCoordinator` + atomic writes).
///
/// This is the production ``FileStore`` for the ``DecisionStore``'s cross-launch persistence
/// (AC5 / FR50 / FR51): unlike the in-memory `EphemeralFileStore` stand-in, decisions written
/// here survive an app relaunch. It is a thin async wrapper that DELEGATES every operation to
/// ``CoordinatedFileStore`` — itself an `actor` — so the actual file I/O runs on that actor's
/// executor, OFF the calling actor (the ``DecisionStore``). That satisfies the "atomic write
/// off the calling actor" requirement (NFR5 / AC5); the `.atomic` write semantics and the
/// intermediate-directory creation both come for free from ``CoordinatedFileStore``.
///
/// Modeled as a `public final actor` so it is `Sendable` and data-race-clean under Swift 6
/// strict concurrency with NO `@unchecked` suppression. Stateless apart from the owned
/// coordinated store: read/write take full URLs, so no Application Support directory is needed
/// here (where the ``DecisionStore`` default points its `fileURL` is DecisionStore wiring).
public final actor ApplicationSupportFileStore: FileStore {
    /// The coordinated, atomic file store every operation delegates to. Owning it as a `let`
    /// keeps this adapter all-`let` and `Sendable` with no suppression; because it is an `actor`,
    /// the delegated I/O hops onto its executor — off this adapter's caller.
    private let coordinated = CoordinatedFileStore()

    /// Creates the durable file store. Stateless — the adapter exists purely to bridge the
    /// async ``FileStore`` port to the synchronous, actor-isolated ``CoordinatedFileStore``.
    public init() {}

    /// Reads the bytes at `url`, delegating to ``CoordinatedFileStore/read(from:)``.
    ///
    /// A missing file propagates the `CocoaError(.fileReadNoSuchFile)` that `Data(contentsOf:)`
    /// throws for an absent file — the throw ``DecisionStore/loadFromDisk()`` relies on to
    /// degrade to an empty store on first launch.
    public func read(from url: URL) async throws -> Data {
        try await coordinated.read(from: url)
    }

    /// Writes `data` to `url` atomically, delegating to ``CoordinatedFileStore/write(_:to:)``.
    ///
    /// The write lands via `.atomic` (no torn write is ever observable) and the parent directory
    /// is created with intermediates first if missing — both inherited from the delegate.
    public func write(_ data: Data, to url: URL) async throws {
        try await coordinated.write(data, to: url)
    }
}
