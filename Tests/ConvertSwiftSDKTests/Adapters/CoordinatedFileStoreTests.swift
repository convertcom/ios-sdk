// Tests/ConvertSwiftSDKTests/Adapters/CoordinatedFileStoreTests.swift
import Testing
import Foundation
import ConvertSwiftSDK

// RED phase (Epic 2, Story 2.3 / 3): this suite exercises `CoordinatedFileStore`,
// the concrete `NSFileCoordinator`-backed file-store adapter, which DOES NOT EXIST
// YET — the GREEN step creates it at
// `Sources/ConvertSwiftSDK/Adapters/CoordinatedFileStore.swift`. Until then this file
// fails to compile with "cannot find 'CoordinatedFileStore' in scope", which is the
// expected RED state for this TDD cycle.
//
// ── Contract under test (for the GREEN implementer) ───────────────────────────
// `public final actor CoordinatedFileStore` with:
//   * `func write(_ data: Data, to url: URL) throws` — creates the parent directory
//     if missing, coordinates the write via `NSFileCoordinator`, then
//     `data.write(to:options:.atomic)`. `atomicWriteAndRead()` drives a URL whose
//     parent dir does not exist, so a passing GREEN MUST create intermediate dirs.
//   * `func read(from url: URL) throws -> Data` — coordinates the read, then
//     `Data(contentsOf: url)`; THROWS when the file is absent
//     (`readOnMissingFileThrows()`).
//   * `func delete(at url: URL)` — removes the file if present; no-throw, ignoring
//     file-not-found (`deleteOnMissingFileDoesNotThrow()`).
//   * `static func configCacheURL(for sdkKey: String) -> URL` — a PURE URL builder
//     (no actor isolation, no I/O): `{applicationSupportDirectory}/`
//     `com.convertexperiments.sdk/config-{sanitizedKey}.json`, where `/` in the key
//     becomes `_` in the FILENAME only.
// Because the store is an `actor`, write/read/delete are `await` (and `try` for the
// throwing two); `configCacheURL` is `static` — NO `await`.
//
// ── Isolation + cleanup shape (NFR21 — no test artifacts leak) ────────────────
// Each I/O test builds a UNIQUE URL under `FileManager.default.temporaryDirectory`
// (a fresh UUID subdirectory + filename) so cases never collide and never touch the
// real Application Support dir. Every UUID dir created by `uniqueURL()` is recorded
// and removed in `deinit` (swift-testing makes a fresh suite instance per `@Test`
// and runs `deinit` after it, giving symmetric after-each teardown).
//
// A `final class` (not `struct`) so the suite can declare a `deinit`: a `struct`
// conforms to `Copyable` and cannot carry one (mirrors `URLSessionHTTPClientTests`).
// The recorded-dirs set is held in a `LockedBox` (the same lock-cell the synchronous
// mocks use, in `MockPorts.swift`) so the mutable instance state is `Sendable`-safe
// under Swift 6 strict concurrency on this package's macOS 12 / iOS 15 floor — where
// `Synchronization.Mutex` is unavailable — and reads soundly from `deinit`.
@Suite("CoordinatedFileStore")
final class CoordinatedFileStoreTests {
    /// Temp directories created by ``uniqueURL()``, removed in ``deinit`` so no test
    /// artifact survives the run. Held in a ``LockedBox`` (defined in
    /// `MockPorts.swift`) so this mutable instance state is `Sendable`-safe and can
    /// be read back during teardown.
    private let createdDirs = LockedBox<[URL]>([])

    /// Removes every temp directory this suite created (NFR21). Runs after each
    /// `@Test` (fresh suite instance per case), so no scratch dir leaks into the
    /// next case or an unrelated suite.
    deinit {
        let manager = FileManager.default
        for dir in createdDirs.get {
            try? manager.removeItem(at: dir)
        }
    }

    /// The system under test. Factored out so no case repeats the construction
    /// (SonarQube new-code duplication discipline).
    private func makeStore() -> CoordinatedFileStore {
        CoordinatedFileStore()
    }

    /// Builds a UNIQUE file URL under a fresh UUID temp subdirectory and records that
    /// subdirectory for ``deinit`` cleanup. The returned URL's PARENT does not exist
    /// on disk yet — exercising the adapter's "create intermediate dirs" contract —
    /// and is unique per call so cases never collide. Centralizing this here is what
    /// keeps the temp-URL construction from being copy-pasted across tests.
    private func uniqueURL(filename: String = "config.json") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        createdDirs.withLock { $0.append(dir) }
        return dir.appendingPathComponent(filename)
    }

    /// Sample payload the round-trip and delete cases write.
    static let payload = Data(#"{"config":"cached"}"#.utf8)

    /// `write` creates the missing parent directory and persists the bytes; `read`
    /// returns exactly what was written. The URL's parent dir does NOT exist before
    /// the write, so a pass proves intermediate-directory creation.
    @Test("write creates intermediate dirs and read returns the written bytes")
    func atomicWriteAndRead() async throws {
        let store = makeStore()
        let url = uniqueURL()

        try await store.write(Self.payload, to: url)
        let readBack = try await store.read(from: url)

        #expect(readBack == Self.payload)
    }

    /// After `delete`, the file is gone — a subsequent `read` THROWS rather than
    /// returning stale bytes.
    @Test("delete removes the file so a later read throws")
    func deleteRemovesFile() async throws {
        let store = makeStore()
        let url = uniqueURL()
        try await store.write(Self.payload, to: url)

        await store.delete(at: url)

        await #expect(throws: (any Error).self) {
            _ = try await store.read(from: url)
        }
    }

    /// `read` on a URL that was never written THROWS (missing file is an error).
    @Test("read on a missing file throws")
    func readOnMissingFileThrows() async {
        let store = makeStore()
        let url = uniqueURL()

        await #expect(throws: (any Error).self) {
            _ = try await store.read(from: url)
        }
    }

    /// `delete` on a URL that was never written does NOT throw (delete is no-throw and
    /// ignores file-not-found). The call is non-throwing, so reaching the follow-up is
    /// itself the proof; we additionally assert the path is still absent (read throws).
    @Test("delete on a missing file does not throw")
    func deleteOnMissingFileDoesNotThrow() async {
        let store = makeStore()
        let url = uniqueURL()

        await store.delete(at: url)

        await #expect(throws: (any Error).self) {
            _ = try await store.read(from: url)
        }
    }

    /// `configCacheURL(for:)` builds the cache path under the Application Support
    /// directory, namespaced by the SDK bundle id, with `/` in the key sanitized to
    /// `_` in the FILENAME. Pure URL construction — no actor hop (`static`, no
    /// `await`) and no file I/O.
    @Test("configCacheURL is under Application Support and sanitizes the key")
    func configCacheURLUsesAppSupportAndSanitizesKey() throws {
        let url = CoordinatedFileStore.configCacheURL(for: "sk_with/slash")

        #expect(url.path.hasSuffix("com.convertexperiments.sdk/config-sk_with_slash.json"))

        let appSupport = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            "no Application Support directory on this platform"
        )
        #expect(url.path.hasPrefix(appSupport.path))
    }
}
