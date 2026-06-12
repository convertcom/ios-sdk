// MockCorePorts.swift
// Test-double conformances for the ConvertSDKCore *persistence* ports consumed by the
// Epic 3 / Story 1 visitor-context suite: `SecureStore`, `KeyValueStore`, and `Logger`.
//
// ── Why a SEPARATE file from Tests/ConvertSDKTests/Support/MockPorts.swift ─────────────
// The two test targets cannot share code: `ConvertSDKCoreTests` depends ONLY on
// `ConvertSDKCore` (Package.swift), while `MockPorts.swift` lives in `ConvertSDKTests`
// (which depends on `ConvertSDK`) and is therefore invisible here. The mocks below
// conform to the *Core* port protocols (`SecureStore`/`KeyValueStore`/`Logger`), which are
// reachable through the `ConvertSDKCore` dependency. `MockLogger` is re-declared here for
// the same visibility reason — the `ConvertSDKTests` one cannot be seen from this target.
//
// ── Concurrency shape per mock ────────────────────────────────────────────────────────
// All three ports refine `Sendable`, so every mock must be `Sendable`. Their requirements
// are SYNCHRONOUS — `read/write/delete` are sync `throws`, `string/set/removeObject` and
// `log(...)` are sync — which an `actor` CANNOT satisfy (actor access is `async`). So each
// mock is a `final class` whose entire mutable state lives in a single `LockedBox` cell,
// exactly as `MockPorts.swift` documents for its synchronous mocks (`MockLogger`/`MockClock`).
//
// `Mutex<Value>` from `Synchronization` — the annotation-free `Sendable` lock-cell — is NOT
// available: it needs macOS 15 / iOS 18, but this package targets macOS 12 / iOS 15
// (Package.swift `platforms`). At that floor the only way a `final class` with lock-guarded
// mutable state can claim `Sendable` is to assert it. `@unchecked Sendable` is forbidden by
// project policy; the sanctioned form is `nonisolated(unsafe)` on the guarded storage, and
// that single annotation is confined to the one `LockedBox` primitive below — the mocks
// themselves carry ZERO suppressions.

import Foundation
@testable import ConvertSDKCore

// MARK: - LockedBox

/// A `Sendable` lock-protected storage cell — the single concurrency primitive behind the
/// synchronous mocks in this file. `value` is the only `nonisolated(unsafe)` declaration:
/// it is sound because every read and write goes through `lock.withLock`, so accesses are
/// mutually exclusive at runtime; the annotation merely tells the Swift 6 compiler "this
/// storage is hand-audited" on a deployment floor (macOS 12 / iOS 15) where
/// `Synchronization.Mutex` is unavailable. Mirrors the primitive in `MockPorts.swift`.
final class LockedBox<Value>: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// The current value, read under the lock.
    var get: Value {
        lock.withLock { value }
    }

    /// Mutates the value in place under the lock and returns the closure's result.
    @discardableResult
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        try lock.withLock { try body(&value) }
    }
}

// MARK: - MockSecureStore

/// Test double for ``SecureStore`` (the Keychain-backed port).
///
/// Shape: `final class` + ``LockedBox`` — `read/write/delete` are synchronous `throws`,
/// which an actor cannot satisfy. One `LockedBox<State>` holds the in-memory backing map,
/// the call counters, and the injected read behavior.
///
/// The `readBehavior` knob models the four Keychain outcomes the resolver must handle:
///   * `.normal`  — return the stored value (or `nil` when the key is absent: a true miss).
///   * `.miss`    — always return `nil` regardless of the backing map (forces the mirror path).
///   * `.empty`   — return `""` (the corrupted/empty-Keychain branch — treated as a miss).
///   * `.throwing`— `read` throws the injected error (the `SecItemCopyMatching` failure branch).
/// `write` always succeeds and records into the backing map (so a backfill is observable).
final class MockSecureStore: SecureStore {
    /// How ``read(key:)`` should behave, injected per scenario.
    enum ReadBehavior: Sendable {
        case normal
        case miss
        case empty
        case throwing(any Error)
    }

    private struct State {
        var storage: [String: String]
        var readCallCount = 0
        var writeCallCount = 0
        var readBehavior: ReadBehavior
    }

    private let state: LockedBox<State>

    init(storage: [String: String] = [:], readBehavior: ReadBehavior = .normal) {
        self.state = LockedBox(State(storage: storage, readBehavior: readBehavior))
    }

    /// Number of times ``read(key:)`` was invoked.
    var readCallCount: Int { state.get.readCallCount }

    /// Number of times ``write(_:key:)`` was invoked.
    var writeCallCount: Int { state.get.writeCallCount }

    /// The value currently stored under `key`, or `nil` (lets a test confirm a backfill landed).
    func value(forKey key: String) -> String? {
        state.get.storage[key]
    }

    func read(key: String) throws -> String? {
        let behavior: ReadBehavior = state.withLock { current in
            current.readCallCount += 1
            return current.readBehavior
        }
        switch behavior {
        case .normal:
            return state.get.storage[key]
        case .miss:
            return nil
        case .empty:
            return ""
        case .throwing(let error):
            throw error
        }
    }

    func write(_ value: String, key: String) throws {
        state.withLock { current in
            current.writeCallCount += 1
            current.storage[key] = value
        }
    }

    func delete(key: String) throws {
        state.withLock { current in
            current.storage.removeValue(forKey: key)
        }
    }
}

// MARK: - MockKeyValueStore

/// Test double for ``KeyValueStore`` (the `UserDefaults`-style mirror port).
///
/// Shape: `final class` + ``LockedBox`` — every requirement is synchronous and non-throwing,
/// which an actor cannot satisfy. One `LockedBox<State>` holds the backing map plus the
/// read/write counters so a test can assert the mirror was consulted and/or written.
final class MockKeyValueStore: KeyValueStore {
    private struct State {
        var storage: [String: String]
        var readCallCount = 0
        var writeCallCount = 0
    }

    private let state: LockedBox<State>

    init(storage: [String: String] = [:]) {
        self.state = LockedBox(State(storage: storage))
    }

    /// Number of times ``string(forKey:)`` was invoked.
    var readCallCount: Int { state.get.readCallCount }

    /// Number of times ``set(_:forKey:)`` was invoked.
    var writeCallCount: Int { state.get.writeCallCount }

    func string(forKey key: String) -> String? {
        state.withLock { current in
            current.readCallCount += 1
            return current.storage[key]
        }
    }

    func set(_ value: String, forKey key: String) {
        state.withLock { current in
            current.writeCallCount += 1
            current.storage[key] = value
        }
    }

    func removeObject(forKey key: String) {
        state.withLock { current in
            current.storage.removeValue(forKey: key)
        }
    }
}

// MARK: - MockLogger

/// Test double for ``Logger``. Re-declared here (not shared from `ConvertSDKTests`) because
/// this target cannot see that module's copy.
///
/// Shape: `final class` + ``LockedBox`` — `log(...)` is a synchronous requirement an actor
/// cannot satisfy. Records each call; ``entries(type:method:)`` filters so a test retrieves
/// only the lines its own subject emitted.
final class MockLogger: Logger {
    /// One captured `log(...)` call.
    struct LogEntry: Sendable {
        let level: LogLevel
        let type: String
        let method: String
        let message: String
    }

    private let entriesBox = LockedBox<[LogEntry]>([])

    func log(level: LogLevel, type: String, method: String, message: String) {
        let entry = LogEntry(level: level, type: type, method: method, message: message)
        entriesBox.withLock { $0.append(entry) }
    }

    /// Returns captured entries, optionally filtered by `type` and/or `method`.
    /// A `nil` filter matches any value for that field.
    func entries(type: String? = nil, method: String? = nil) -> [LogEntry] {
        entriesBox.get.filter { entry in
            (type == nil || entry.type == type) && (method == nil || entry.method == method)
        }
    }
}

// MARK: - MockEventSink

/// Test double for ``EventSink`` (the decisioning → queue enqueue seam consumed by the
/// Epic 3 / Story 2 bucketing suite). Re-declared here (not shared from `ConvertSDKTests`)
/// for the same target-visibility reason as ``MockLogger`` above — `ConvertSDKCoreTests`
/// cannot see the `ConvertSDKTests` copy in `MockPorts.swift`.
///
/// Shape: `actor` — `enqueue(_:)` is `async`, so actor isolation satisfies the port with
/// no `Sendable` suppression (unlike the synchronous ports above, which need ``LockedBox``).
/// Records enqueued entries; a test reads them via ``recordedEvents()`` (awaited, since the
/// accessor is actor-isolated).
actor MockEventSink: EventSink {
    private var recorded: [TrackingEventEntry] = []

    func enqueue(_ event: TrackingEventEntry) async {
        recorded.append(event)
    }

    /// Returns the recorded entries without clearing them.
    func recordedEvents() -> [TrackingEventEntry] {
        recorded
    }
}

// MARK: - MockFileStore

/// Test double for ``FileStore`` (the atomic file-I/O port the `DecisionStore` persists
/// through). Re-declared here (not shared from `ConvertSDKTests`) for the same
/// target-visibility reason as ``MockLogger`` / ``MockEventSink`` above — `ConvertSDKCoreTests`
/// cannot see the `ConvertSDKTests` copy in `MockPorts.swift`. Mirrors that copy's API
/// (`init(files:)`, `read` throwing `CocoaError(.fileReadNoSuchFile)` on a miss, `write`,
/// `seed(_:at:)`, `contents(at:)`) and adds ONE knob below.
///
/// Shape: `actor` — `read`/`write` are `async throws`, so actor isolation satisfies the port
/// with NO `Sendable` suppression (no ``LockedBox`` needed, unlike the synchronous mocks).
///
/// ── `corruptAllReads` knob ──────────────────────────────────────────────────────────────
/// When set, EVERY ``read(from:)`` returns this blob regardless of the requested URL. The
/// corruption-recovery test needs the store to read invalid JSON, but the on-disk URL the
/// `DecisionStore` computes internally is opaque to the test — so seeding by a known URL is
/// brittle. This knob makes the corrupt-bytes read robust to whatever path the store requests.
/// `nil` (the default) leaves `read` driven by the in-memory `files` map, exactly like the
/// `MockPorts.swift` copy.
actor MockFileStore: FileStore {
    private var files: [String: Data]
    private let corruptAllReads: Data?

    init(files: [URL: Data] = [:], corruptAllReads: Data? = nil) {
        self.files = Dictionary(
            uniqueKeysWithValues: files.map { ($0.key.absoluteString, $0.value) }
        )
        self.corruptAllReads = corruptAllReads
    }

    func read(from url: URL) async throws -> Data {
        if let corruptAllReads {
            return corruptAllReads
        }
        guard let data = files[url.absoluteString] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }

    func write(_ data: Data, to url: URL) async throws {
        files[url.absoluteString] = data
    }

    /// Pre-seeds (or overwrites) the data stored at `url`.
    func seed(_ data: Data, at url: URL) {
        files[url.absoluteString] = data
    }

    /// Returns the data currently stored at `url`, or `nil` if absent.
    func contents(at url: URL) -> Data? {
        files[url.absoluteString]
    }
}

// MARK: - makeManager factory

/// The mocks a visitor-context scenario drives, returned as a named struct (not a tuple) so
/// call sites read fields by name and the `large_tuple` lint rule stays satisfied.
struct ManagerHarness {
    let secureStore: MockSecureStore
    let keyValueStore: MockKeyValueStore
    let logger: MockLogger
}

/// Builds the three mocks for one scenario in a single call, so no test re-wires the trio
/// inline (SonarQube 3% new-duplicated-lines gate). `keychainValue` pre-seeds the Keychain
/// under ``StorageKeys/visitorId``; `userDefaultsValue` pre-seeds the mirror under
/// ``StorageKeys/visitorIdMirror``. `secureReadBehavior` injects the Keychain read outcome
/// (`.normal` by default; `.empty`/`.throwing` exercise the corrupted/failure branches).
func makeManager(
    keychainValue: String? = nil,
    userDefaultsValue: String? = nil,
    secureReadBehavior: MockSecureStore.ReadBehavior = .normal
) -> ManagerHarness {
    var keychain: [String: String] = [:]
    if let keychainValue {
        keychain[StorageKeys.visitorId] = keychainValue
    }
    var defaults: [String: String] = [:]
    if let userDefaultsValue {
        defaults[StorageKeys.visitorIdMirror] = userDefaultsValue
    }
    return ManagerHarness(
        secureStore: MockSecureStore(storage: keychain, readBehavior: secureReadBehavior),
        keyValueStore: MockKeyValueStore(storage: defaults),
        logger: MockLogger()
    )
}
