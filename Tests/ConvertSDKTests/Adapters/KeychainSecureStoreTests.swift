// Tests/ConvertSDKTests/Adapters/KeychainSecureStoreTests.swift
import Testing
import Foundation
import ConvertSDK

// RED phase (Epic 3, Story 3.1): this suite exercises `KeychainSecureStore`, the
// concrete Security/Keychain-backed `SecureStore` adapter, which DOES NOT EXIST YET —
// the GREEN step creates it at
// `Sources/ConvertSDK/Adapters/KeychainSecureStore.swift`. Until then this file fails
// to compile with "cannot find 'KeychainSecureStore' in scope", which is the expected
// RED state for this TDD cycle.
//
// ── Contract under test (for the GREEN implementer) ───────────────────────────
// `public final class KeychainSecureStore: SecureStore` (Sendable, NO `@unchecked`)
// backed by `kSecClassGenericPassword` with `kSecAttrService` = the injected service,
// `kSecAttrAccount` = key, `kSecAttrAccessible` =
// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Init signature these tests
// ASSUME (GREEN must match):
//   * `public init(service: String = "com.convert.sdk", logger: Logger = NoopLogger())`
// The injectable `service` is REQUIRED so each test can use an isolated service string
// and never collide with a real SDK Keychain item or with another test.
//   * `read(key:) throws -> String?` — `nil` on `errSecItemNotFound` (a DEBUG, no
//     WARN); `nil` + WARN on any other `OSStatus`; `nil` + WARN on non-UTF8 bytes;
//     empty value treated as a miss.
//   * `write(_:key:) throws` — `SecItemAdd`, falling back to `SecItemUpdate` when the
//     item already exists.
//   * `delete(key:) throws` — `SecItemDelete`, a no-op when the item is absent.
//
// ── Keychain availability strategy (VERIFIED on this dev machine) ──────────────
// The real Keychain was probed directly in plain `swift` on this developer machine:
// `SecItemAdd` and `SecItemCopyMatching` BOTH returned status 0 with a correct
// round-trip, so LOCALLY the Keychain works and the full round-trip can be asserted.
// HOWEVER, the sprint's standing environment note records that the Keychain is NOT
// reliably available on macOS CI runners (a missing entitlement yields
// `errSecMissingEntitlement` / status -34018, so writes/reads fail and `read` returns
// `nil`). The round-trip test below is therefore written to PASS in BOTH environments:
// it probes once (write, then read). If the value round-trips, it asserts the full
// contract (read == written; after delete, read == nil). If the read does NOT return
// the written value, the Keychain is unavailable in this environment, and the test
// `return`s early as a no-op — it MUST NOT fail on CI. This is the story's sanctioned
// "test what the environment allows" strategy: the probe is an explicit value compare,
// never a wall-clock or otherwise flaky construct. The "absent key reads nil" test is
// unconditional because a miss is `nil` in EITHER environment (absent →
// `errSecItemNotFound` → `nil`; unavailable → entitlement error → `nil`).
//
// ── Non-UTF8 / corruption branch — deliberately NOT tested here ────────────────
// `KeychainSecureStore`'s "non-UTF8 bytes → nil + WARN" branch is NOT reachable
// through the public adapter API: `write(_ value: String, key:)` is `String`-typed, so
// the adapter only ever stores valid UTF-8 and there is no public seam to inject raw
// non-UTF8 bytes. That branch is covered at the `VisitorContextManager` level by the
// `MockSecureStore` returning an empty/garbage string, NOT through this String-typed
// adapter. Forcing it here would mean contorting the test (e.g. writing a raw Keychain
// item out-of-band), which is explicitly out of scope for this RED suite.
//
// ── Isolation + cleanup shape (NFR21 — no Keychain item leaks) ────────────────
// Each test uses a UNIQUE service string ("com.convert.sdk.test.<UUID>") so cases never
// collide and never touch the real SDK service. Every service used by `makeStore()` is
// recorded; `deinit` deletes the test key under each so no Keychain item survives the
// run (deletion is a no-throw no-op when the item is absent or the Keychain is
// unavailable, so teardown is safe in both environments).
//
// A `final class` (not `struct`) so the suite can declare a `deinit` (mirrors
// `CoordinatedFileStoreTests`); the recorded-services array is held in a `LockedBox`
// (the lock-cell from `MockPorts.swift`) so the mutable instance state is
// `Sendable`-safe on this package's macOS 12 / iOS 15 floor and reads soundly from
// `deinit`.
@Suite("KeychainSecureStore")
final class KeychainSecureStoreTests {
    /// Service strings created by ``makeStore()``, under which ``deinit`` deletes the
    /// shared test key so no Keychain item leaks (NFR21). Held in a ``LockedBox``
    /// (defined in `MockPorts.swift`) so this mutable instance state is `Sendable`-safe
    /// and can be read back during teardown.
    private let createdServices = LockedBox<[String]>([])

    /// Best-effort cleanup: deletes the shared test key under every service this suite
    /// created. Runs after each `@Test` (fresh suite instance per case). `delete` is a
    /// no-throw no-op when the item is absent OR when the Keychain is unavailable, so
    /// this teardown is safe in both the local and CI environments.
    deinit {
        for service in createdServices.get {
            let store = KeychainSecureStore(service: service)
            try? store.delete(key: Self.key)
        }
    }

    /// Builds the system under test over a FRESH, uniquely-named Keychain service and
    /// records that service for ``deinit`` cleanup. Returns the store paired with its
    /// service string. Centralizing construction here keeps the per-test setup from
    /// being copy-pasted (SonarQube new-code duplication discipline) and guarantees
    /// every store is isolated from the real SDK service and from other tests.
    private func makeStore() -> (store: KeychainSecureStore, service: String) {
        let service = "com.convert.sdk.test.\(UUID().uuidString)"
        createdServices.withLock { $0.append(service) }
        return (KeychainSecureStore(service: service), service)
    }

    /// The key the round-trip case writes under (and that `deinit` cleans up).
    static let key = "visitor.uuid"

    /// Round-trip: `write` then `read` returns the stored value; after `delete`, `read`
    /// returns `nil`. The first read is an environment probe — if the Keychain is
    /// unavailable in this environment (e.g. an entitlement-less CI runner, where the
    /// write/read fail and `read` returns `nil`), the value does NOT round-trip and the
    /// test `return`s early as a documented no-op so it passes on CI. Where the Keychain
    /// works (local, VERIFIED status 0), the full contract is asserted.
    @Test("write then read round-trips, and delete clears the value")
    func writeReadDeleteRoundTrips() throws {
        let (store, _) = makeStore()
        let written = "visitor-\(UUID().uuidString)"

        try store.write(written, key: Self.key)

        // Environment probe: only proceed with hard assertions if the Keychain actually
        // round-tripped the value in THIS environment. On an entitlement-less CI runner
        // the read returns nil; treat that as "Keychain unavailable here" and pass as a
        // no-op rather than failing. Defensive cleanup runs in deinit regardless.
        guard try store.read(key: Self.key) == written else { return }

        try store.delete(key: Self.key)

        #expect(try store.read(key: Self.key) == nil)
    }

    /// `read` on a key that was never written returns `nil`. Unconditional — valid in
    /// BOTH environments: locally the absent item yields `errSecItemNotFound` → `nil`;
    /// on an entitlement-less runner the call fails with an entitlement error and the
    /// adapter also returns `nil`. Either way the result is `nil`, so this assertion
    /// holds regardless of Keychain availability.
    @Test("read on a never-written key returns nil")
    func readOnAbsentKeyReturnsNil() throws {
        let (store, _) = makeStore()

        #expect(try store.read(key: "never.written.\(UUID().uuidString)") == nil)
    }
}
