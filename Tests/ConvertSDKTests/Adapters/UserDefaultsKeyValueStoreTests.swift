// Tests/ConvertSDKTests/Adapters/UserDefaultsKeyValueStoreTests.swift
import Testing
import Foundation
import ConvertSDK

// RED phase (Epic 3, Story 3.1): this suite exercises `UserDefaultsKeyValueStore`,
// the concrete `UserDefaults`-backed `KeyValueStore` adapter, which DOES NOT EXIST
// YET — the GREEN step creates it at
// `Sources/ConvertSDK/Adapters/UserDefaultsKeyValueStore.swift`. Until then this file
// fails to compile with "cannot find 'UserDefaultsKeyValueStore' in scope", which is
// the expected RED state for this TDD cycle.
//
// ── Contract under test (for the GREEN implementer) ───────────────────────────
// `public final class UserDefaultsKeyValueStore: KeyValueStore` (Sendable, NO
// `@unchecked`) with an INJECTABLE backing store so tests never pollute
// `UserDefaults.standard`:
//   * `public init(defaults: UserDefaults = .standard)`
//   * `func string(forKey:) -> String?` — delegates to `defaults.string(forKey:)`.
//   * `func set(_:forKey:)`            — delegates to `defaults.set(_:forKey:)`.
//   * `func removeObject(forKey:)`     — delegates to `defaults.removeObject(forKey:)`.
// (`UserDefaults` is itself documented as thread-safe, so the GREEN type needs no
// lock; how it claims `Sendable` over the `UserDefaults` reference is the GREEN
// implementer's call — these tests only pin the init signature + the three delegating
// methods.)
//
// ── Isolation + cleanup shape (NFR21 — no test artifacts leak) ────────────────
// Each test builds a FRESH `UserDefaults(suiteName:)` with a UNIQUE suite name (a new
// UUID) so cases never collide and `UserDefaults.standard` is never touched. Every
// suite name created by `makeStore()` is recorded and its persistent domain removed in
// `deinit` (swift-testing makes a fresh suite instance per `@Test` and runs `deinit`
// after it, giving symmetric after-each teardown).
//
// A `final class` (not `struct`) so the suite can declare a `deinit`: a `struct`
// conforms to `Copyable` and cannot carry one (mirrors `CoordinatedFileStoreTests`).
// The recorded-names array is held in a `LockedBox` (the lock-cell from
// `MockPorts.swift`) so the mutable instance state is `Sendable`-safe under Swift 6
// strict concurrency on this package's macOS 12 / iOS 15 floor — where
// `Synchronization.Mutex` is unavailable — and reads soundly from `deinit`.
@Suite("UserDefaultsKeyValueStore")
final class UserDefaultsKeyValueStoreTests {
    /// Suite names created by ``makeStore()``, whose persistent domains are removed in
    /// ``deinit`` so no scratch defaults survive the run (NFR21). Held in a
    /// ``LockedBox`` (defined in `MockPorts.swift`) so this mutable instance state is
    /// `Sendable`-safe and can be read back during teardown.
    private let createdSuiteNames = LockedBox<[String]>([])

    /// Removes the persistent domain for every suite name this suite created. Runs
    /// after each `@Test` (fresh suite instance per case), so no scratch defaults leak
    /// into the next case or an unrelated suite.
    deinit {
        let defaults = UserDefaults.standard
        for name in createdSuiteNames.get {
            defaults.removePersistentDomain(forName: name)
        }
    }

    /// Builds the system under test over a FRESH, uniquely-named `UserDefaults` suite
    /// and records that suite name for ``deinit`` cleanup. Returns the store paired
    /// with its suite name so a case can reference the isolated domain if needed.
    /// Centralizing construction here keeps the per-test setup from being copy-pasted
    /// (SonarQube new-code duplication discipline) and guarantees every store is
    /// isolated from `UserDefaults.standard`.
    private func makeStore() -> (store: UserDefaultsKeyValueStore, suiteName: String) {
        let suiteName = "com.convert.sdk.test.kv.\(UUID().uuidString)"
        createdSuiteNames.withLock { $0.append(suiteName) }
        // `UserDefaults(suiteName:)` for a fresh, never-registered name is non-nil; if
        // the platform ever returned nil, falling back to `.standard` would still let
        // the test run (the unique key namespace keeps it isolated in practice).
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return (UserDefaultsKeyValueStore(defaults: defaults), suiteName)
    }

    /// The key the round-trip cases write under. A single shared constant so the cases
    /// don't each restate a literal.
    static let key = "visitor.id"

    /// `set` then `string(forKey:)` returns exactly the value that was stored.
    @Test("set then string round-trips the value")
    func setThenStringRoundTrips() {
        let (store, _) = makeStore()

        store.set("abc-123", forKey: Self.key)

        #expect(store.string(forKey: Self.key) == "abc-123")
    }

    /// `string(forKey:)` returns `nil` for a key that was never written.
    @Test("string returns nil for an absent key")
    func stringReturnsNilForAbsentKey() {
        let (store, _) = makeStore()

        #expect(store.string(forKey: "never.written") == nil)
    }

    /// After `removeObject`, the value is gone — a subsequent `string(forKey:)` returns
    /// `nil` rather than the stale value.
    @Test("removeObject deletes so a later string returns nil")
    func removeObjectDeletesValue() {
        let (store, _) = makeStore()
        store.set("to-be-removed", forKey: Self.key)

        store.removeObject(forKey: Self.key)

        #expect(store.string(forKey: Self.key) == nil)
    }

    /// Writing a key a second time returns the NEW value — `set` overwrites rather than
    /// preserving the first write.
    @Test("overwriting a key returns the new value")
    func overwritingKeyReturnsNewValue() {
        let (store, _) = makeStore()
        store.set("first", forKey: Self.key)

        store.set("second", forKey: Self.key)

        #expect(store.string(forKey: Self.key) == "second")
    }
}
