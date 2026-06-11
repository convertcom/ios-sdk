// MockPorts.swift
// Test-double conformances for the five inward-facing ConvertSDKCore ports
// (`HTTPClient`, `EventSink`, `FileStore`, `Logger`, `Clock`), consumed by the
// Epic 2–5 test suites. This file is a COMPILATION STUB for Story 1.3 (AC8/AC9):
// it carries no behavior tests of its own — the smoke test lives elsewhere — but
// it MUST compile zero-warning under Swift 6 strict concurrency (language mode 6).
//
// ── Concurrency shape per mock (AC9) ──────────────────────────────────────────
// All five ports refine `Sendable`, so every mock must be `Sendable`. Two
// compiler-blessed shapes are used, chosen by whether the port's requirements are
// `async`:
//
//   * `actor` — `MockHTTPClient`, `MockEventSink`, `MockFileStore`. Every
//     requirement on these ports is `async`, so an actor satisfies them with the
//     compiler fully reasoning about isolation: NO `@unchecked Sendable`, NO
//     `nonisolated(unsafe)`, NO lock.
//   * `final class` + `LockedBox` — `MockLogger`, `MockClock`. Their requirements
//     are SYNCHRONOUS (`func log(...)`, `var now: Date { get }`), which an actor
//     cannot satisfy (actor access is async). Their mutable state is held in a
//     single `LockedBox` cell (see below).
//
// `Mutex<Value>` from `Synchronization` — the modern lock-cell that the compiler
// accepts as `Sendable` with mutable contents and needs no annotation — is NOT
// available here: it requires macOS 15 / iOS 18, but this package targets
// macOS 12 / iOS 15 (see Package.swift `platforms`). At that deployment floor the
// only way a `final class` with lock-guarded mutable state can claim `Sendable`
// is to assert it to the compiler. `@unchecked Sendable` is forbidden by project
// policy; the sanctioned last-resort form is `nonisolated(unsafe)` on the guarded
// storage. That single annotation is confined to the one `LockedBox` primitive
// below — the synchronous mocks themselves contain zero suppressions, and the
// shared cell also removes the copy-paste lock/accessor block that would
// otherwise repeat across them.

import Foundation
import ConvertSDK

// MARK: - LockedBox

/// A `Sendable` lock-protected storage cell — the single concurrency primitive
/// behind the synchronous mocks (`MockLogger`, `MockClock`).
///
/// `value` is the only `nonisolated(unsafe)` declaration in this file. It is sound
/// because every read and write goes through `lock.withLock`, so accesses are
/// mutually exclusive at runtime; the annotation merely tells the Swift 6 compiler
/// "this storage is hand-audited" on a deployment floor (macOS 12 / iOS 15) where
/// `Synchronization.Mutex` — the annotation-free alternative — is unavailable. The
/// audit surface is exactly these few lines, not each mock that stores state.
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

    /// Replaces the value under the lock.
    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }

    /// Mutates the value in place under the lock and returns the closure's result.
    @discardableResult
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        try lock.withLock { try body(&value) }
    }
}

// MARK: - MockHTTPClient

/// Test double for ``HTTPClient``.
///
/// Shape: `actor` — both `get` and `post` are `async throws`, so actor isolation
/// satisfies the port with no `Sendable` suppression. A canned success response
/// and/or a canned `URLError` are injected up front; `get`/`post` then either
/// throw the error (error takes precedence) or return the response.
///
/// Default behavior when neither is configured: throw `URLError(.badServerResponse)`,
/// so a test that forgets to stub the transport fails loudly rather than silently
/// observing an empty body.
actor MockHTTPClient: HTTPClient {
    /// One recorded outbound request. `body` is `nil` for `get`. A named struct
    /// (rather than a tuple) keeps the `large_tuple` lint rule satisfied and lets
    /// tests read fields by name.
    struct Request: Sendable {
        let url: URL
        let headers: [String: String]
        let body: Data?
    }

    private var cannedResponse: (Data, HTTPURLResponse)?
    private var cannedError: URLError?

    /// Records every request the client was asked to send, in order. Lets tests
    /// assert what was requested.
    private(set) var requests: [Request] = []

    init(
        response: (Data, HTTPURLResponse)? = nil,
        error: URLError? = nil
    ) {
        self.cannedResponse = response
        self.cannedError = error
    }

    /// Sets (or clears) the canned success response returned by `get`/`post`.
    func setResponse(_ response: (Data, HTTPURLResponse)?) {
        cannedResponse = response
    }

    /// Sets (or clears) the canned error thrown by `get`/`post`. When set, the
    /// error is thrown in preference to returning any configured response.
    func setError(_ error: URLError?) {
        cannedError = error
    }

    func get(url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        requests.append(Request(url: url, headers: headers, body: nil))
        return try result()
    }

    func post(url: URL, headers: [String: String], body: Data) async throws -> (Data, HTTPURLResponse) {
        requests.append(Request(url: url, headers: headers, body: body))
        return try result()
    }

    /// Shared resolution: throw the canned error, else return the canned response,
    /// else throw the documented default.
    private func result() throws -> (Data, HTTPURLResponse) {
        if let cannedError {
            throw cannedError
        }
        if let cannedResponse {
            return cannedResponse
        }
        throw URLError(.badServerResponse)
    }
}

// MARK: - MockEventSink

/// Test double for ``EventSink``.
///
/// Shape: `actor` — `enqueue(_:)` is `async`, so actor isolation satisfies the
/// port with no `Sendable` suppression. Records enqueued entries; tests read them
/// non-destructively via ``recordedEvents()`` or destructively via ``drain()``.
actor MockEventSink: EventSink {
    private var recorded: [TrackingEventEntry] = []

    func enqueue(_ event: TrackingEventEntry) async {
        recorded.append(event)
    }

    /// Returns the recorded entries without clearing them.
    func recordedEvents() -> [TrackingEventEntry] {
        recorded
    }

    /// Returns the recorded entries and clears the buffer.
    func drain() -> [TrackingEventEntry] {
        defer { recorded.removeAll() }
        return recorded
    }
}

// MARK: - MockFileStore

/// Test double for ``FileStore``.
///
/// Shape: `actor` — `read`/`write` are `async throws`, so actor isolation
/// satisfies the port with no `Sendable` suppression. Backed by an in-memory map
/// keyed on the URL's `absoluteString`. `read(from:)` throws
/// `CocoaError(.fileReadNoSuchFile)` for an absent path. Tests can pre-seed and
/// inspect the contents.
actor MockFileStore: FileStore {
    private var files: [String: Data]

    init(files: [URL: Data] = [:]) {
        self.files = Dictionary(
            uniqueKeysWithValues: files.map { ($0.key.absoluteString, $0.value) }
        )
    }

    func read(from url: URL) async throws -> Data {
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

// MARK: - MockLogger

/// Test double for ``Logger``.
///
/// Shape: `final class` + ``LockedBox`` — `log(...)` is a synchronous requirement,
/// which an actor cannot satisfy. Records each call. Per NFR21, ``entries(type:method:)``
/// filters so a test can retrieve only the lines its own subject emitted.
final class MockLogger: Logger {
    /// One captured `log(...)` call.
    struct LogEntry: Sendable {
        let level: LogLevel
        let type: String
        let method: String
        let message: String
    }

    private let box = LockedBox<[LogEntry]>([])

    func log(level: LogLevel, type: String, method: String, message: String) {
        box.withLock {
            $0.append(LogEntry(level: level, type: type, method: method, message: message))
        }
    }

    /// Returns captured entries, optionally filtered by `type` and/or `method`.
    /// A `nil` filter matches any value for that field.
    func entries(type: String? = nil, method: String? = nil) -> [LogEntry] {
        box.get.filter { entry in
            (type == nil || entry.type == type) && (method == nil || entry.method == method)
        }
    }
}

// MARK: - MockClock

/// Test double for ``Clock``.
///
/// Shape: `final class` + ``LockedBox`` — `now` is a synchronous getter, which an
/// actor cannot satisfy, so this is the one port for which `final class` + a lock
/// is mandatory. Tests inject deterministic time via ``setNow(_:)``. Defaults to
/// the Unix epoch so an unconfigured clock is still deterministic.
final class MockClock: Clock {
    private let box: LockedBox<Date>

    init(now: Date = Date(timeIntervalSince1970: 0)) {
        self.box = LockedBox(now)
    }

    var now: Date {
        box.get
    }

    /// Sets the instant returned by ``now``.
    func setNow(_ date: Date) {
        box.set(date)
    }
}

// MARK: - MockConfigLoader

/// Test double for ``ConfigLoader`` that always succeeds (Story 2.2 entry-point suites).
///
/// Shape: `actor` — `load(sdkKey:)` is the sole `async` requirement, so actor isolation
/// satisfies the port with no `Sendable` suppression (mirrors ``MockHTTPClient`` /
/// ``MockEventSink``). It records every key it was asked to load, in order, so a test can
/// assert the SDK forwarded the configured key; the call itself returns immediately. This
/// is the loader the entry-point happy-path suites inject so `ready()` resolves without
/// touching the network.
actor MockConfigLoader: ConfigLoader {
    /// Every `sdkKey` the loader was asked to load, in call order. Lets tests assert the
    /// SDK forwarded the configured key to its loader.
    private(set) var loadedKeys: [String] = []

    func load(sdkKey: String) async throws {
        loadedKeys.append(sdkKey)
    }
}

// MARK: - FailingMockConfigLoader

/// Test double for ``ConfigLoader`` that simulates a transient network failure.
///
/// Shape: `actor` — same rationale as ``MockConfigLoader``. `load(sdkKey:)` always throws
/// `URLError(.notConnectedToInternet)` to model the offline / transport-failure path. The
/// SDK's config-load task is expected to CATCH this and still resolve `ready()` degraded
/// (never rethrowing a transient network error); the entry-point degraded-path suite
/// injects this loader to exercise that contract.
actor FailingMockConfigLoader: ConfigLoader {
    func load(sdkKey: String) async throws {
        throw URLError(.notConnectedToInternet)
    }
}
