// Tests/ConvertSwiftSDKTests/Adapters/ApplicationSupportFileStoreTests.swift
import Testing
import Foundation
import ConvertSwiftSDK

// RED phase (Epic 3, Story 3.4 / FS-1): this suite exercises
// `ApplicationSupportFileStore`, the async `FileStore`-conforming durable on-disk
// adapter that backs `DecisionStore` cross-launch persistence (AC5 / FR50 / FR51).
// It DOES NOT EXIST YET — the GREEN step creates it at
// `Sources/ConvertSwiftSDK/Adapters/ApplicationSupportFileStore.swift`. Until then this
// file fails to compile with "cannot find 'ApplicationSupportFileStore' in scope",
// which is the expected RED state for this TDD cycle.
//
// The existing `CoordinatedFileStore` is an `actor` with SYNCHRONOUS `read`/`write`
// (NSFileCoordinator + `.atomic`) and does NOT conform to the async `FileStore`
// port; the DecisionStore default currently uses the in-memory `EphemeralFileStore`
// stand-in. FS-1 adds this async adapter (the simplest correct impl delegates to
// `CoordinatedFileStore` internally) and the wiring swaps it in for the durable
// default. This suite pins only the adapter's read/write CONTRACT — the
// DecisionStore wiring is exercised by the GREEN implementer, not here.
//
// ── Contract under test (for the GREEN implementer) ───────────────────────────
// A `public final actor` (or final class) `ApplicationSupportFileStore: FileStore`
// with:
//   * `public init()` — stateless; read/write take full URLs, so the tests inject
//     temp URLs and the adapter never needs an Application Support directory for
//     these cases. (Where the DecisionStore default points its fileURL — under
//     Application Support — is DecisionStore/ConvertSwiftSDK wiring, NOT this adapter.)
//   * `func read(from url: URL) async throws -> Data` — returns the bytes;
//     THROWS when the file is absent (`readMissingFileThrows()`). The missing-file
//     signal MUST stay a THROW (not a hang, not a crash) so
//     `DecisionStore.loadFromDisk()` degrades to an empty store. The reference
//     backings surface `CocoaError(.fileReadNoSuchFile)` here — what
//     `Data(contentsOf:)` throws for a missing file; a delegating GREEN inherits it.
//   * `func write(_ data: Data, to url: URL) async throws` — atomic write that
//     creates intermediate directories. `writeThenReadReturnsBytes()` drives a URL
//     whose parent dir does not exist, so a passing GREEN MUST create it.
// Because the adapter is an `actor`, read/write are `await` + `try`.
//
// ── Isolation + cleanup shape (NFR21 — no test artifacts leak) ────────────────
// Mirrors `CoordinatedFileStoreTests` exactly. Each I/O test builds a UNIQUE URL
// under `FileManager.default.temporaryDirectory` (a fresh UUID subdirectory +
// filename) so cases never collide and never touch the real Application Support
// dir. Every UUID dir created by `uniqueURL()` is recorded and removed in `deinit`
// (swift-testing makes a fresh suite instance per `@Test` and runs `deinit` after
// it, giving symmetric after-each teardown).
//
// A `final class` (not `struct`) so the suite can declare a `deinit`: a `struct`
// conforms to `Copyable` and cannot carry one. The recorded-dirs set is held in a
// `LockedBox` (defined in `MockPorts.swift`) so the mutable instance state is
// `Sendable`-safe under Swift 6 strict concurrency on this package's macOS 12 /
// iOS 15 floor — where `Synchronization.Mutex` is unavailable — and reads soundly
// from `deinit`.
@Suite("ApplicationSupportFileStore")
final class ApplicationSupportFileStoreTests {
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
    private func makeStore() -> ApplicationSupportFileStore {
        ApplicationSupportFileStore()
    }

    /// Builds a UNIQUE file URL under a fresh UUID temp subdirectory and records that
    /// subdirectory for ``deinit`` cleanup. The returned URL's PARENT does not exist
    /// on disk yet — exercising the adapter's "create intermediate dirs" contract —
    /// and is unique per call so cases never collide. Centralizing this here is what
    /// keeps the temp-URL construction from being copy-pasted across tests.
    private func uniqueURL(filename: String = "decisions.json") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        createdDirs.withLock { $0.append(dir) }
        return dir.appendingPathComponent(filename)
    }

    /// Sample payload the round-trip cases write.
    static let payload = Data(#"{"decisions":"persisted"}"#.utf8)
    /// Replacement payload the overwrite case writes over ``payload``.
    static let replacement = Data(#"{"decisions":"replaced"}"#.utf8)

    /// `write` creates the missing parent directory and persists the bytes; `read`
    /// returns exactly what was written. The URL's parent dir does NOT exist before
    /// the write, so a pass proves the async round-trip AND intermediate-directory
    /// creation.
    @Test("write creates intermediate dirs and read returns the written bytes")
    func writeThenReadReturnsBytes() async throws {
        let store = makeStore()
        let url = uniqueURL()

        try await store.write(Self.payload, to: url)
        let readBack = try await store.read(from: url)

        #expect(readBack == Self.payload)
    }

    /// `read` on a URL that was never written THROWS (missing file is an error, not a
    /// hang or a crash). This is the behavior `DecisionStore.loadFromDisk()` relies on
    /// to degrade to an empty store on first launch.
    @Test("read on a missing file throws")
    func readMissingFileThrows() async {
        let store = makeStore()
        let url = uniqueURL()

        await #expect(throws: (any Error).self) {
            _ = try await store.read(from: url)
        }
    }

    /// A second `write` to the same URL atomically REPLACES the contents: a later
    /// `read` returns the second payload, never the first or a torn blend.
    @Test("write twice replaces contents and read returns the latest")
    func overwriteReplacesContents() async throws {
        let store = makeStore()
        let url = uniqueURL()

        try await store.write(Self.payload, to: url)
        try await store.write(Self.replacement, to: url)
        let readBack = try await store.read(from: url)

        #expect(readBack == Self.replacement)
    }

    /// The adapter satisfies the `FileStore` port: assigned to an `any FileStore`
    /// existential, a write-then-read round-trips identically — proving the
    /// conformance the DecisionStore default depends on to accept it as its
    /// `fileStore`.
    @Test("round-trips through the FileStore protocol existential")
    func roundTripThroughFileStoreProtocol() async throws {
        let fileStore: any FileStore = makeStore()
        let url = uniqueURL()

        try await fileStore.write(Self.payload, to: url)
        let readBack = try await fileStore.read(from: url)

        #expect(readBack == Self.payload)
    }
}
