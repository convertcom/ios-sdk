// Tests/ConvertSDKCoreTests/Visitor/VisitorContextManagerTests.swift
// Contract for `VisitorContextManager.resolveVisitorId(...)` (Epic 3 / Story 1).
//
// `@testable import ConvertSDKCore` is used to reach `StorageKeys` (`internal`) and the
// `package`-scoped `VisitorContextManager` from this same-package test target (matching the
// pattern in `Data/ConfigStoreTests.swift`). The production types exist on disk and this suite
// compiles and passes.
//
// CONTRACT under test (the GREEN-phase implementer MUST satisfy these):
//   * `provided` non-nil AND non-empty → returned AS-IS, with NO store reads and NO writes
//     (never trimmed or case-folded).
//   * else read the Keychain (`secureStore.read(key: StorageKeys.visitorId)`):
//       - success & non-empty → returned verbatim, no new write.
//       - Keychain MISS (`nil`) → read the mirror (`keyValueStore.string(forKey:)`):
//           · present → returned AND backfilled into the Keychain (one write).
//           · absent  → a fresh `UUID().uuidString` is generated, written to BOTH stores,
//             and returned; an `[INFO]` "no persisted visitor ID found, generating new UUID"
//             line is logged.
//       - corrupted/empty (`""`) → treated as a miss; falls through and generates a UUID.
//       - read THROWS → a `[WARN]` "storage error" line is logged; NEVER rethrown; falls back
//         gracefully and generates a fresh UUID.
import Foundation
import Testing
@testable import ConvertSDKCore

@Suite("VisitorContextManager")
struct VisitorContextManagerTests {
    // MARK: Shared fixtures & helpers (SonarQube 3% new-duplicated-lines gate)

    /// Swift's `UUID().uuidString` is an UPPERCASE, hyphen-grouped 8-4-4-4-12 string. One
    /// anchored regex, declared once, validates every generation path instead of re-inlining
    /// the pattern per test (SonarQube CPD matches on tokens, so a re-inlined literal counts).
    static let uuidPattern = "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"

    /// One assertion helper for "this string is a freshly generated UUID", so the regex check
    /// is written once rather than copied across the generation cases.
    private func expectIsGeneratedUUID(_ value: String, _ comment: Comment) {
        #expect(
            value.range(of: Self.uuidPattern, options: .regularExpression) != nil,
            comment
        )
    }

    /// Resolves through the manager using a harness, returning the result plus the harness so a
    /// test can both assert the value and inspect call counts / logs. Keeps the call shape in one
    /// place so no test re-spells the four-argument `resolveVisitorId` invocation.
    private func resolve(
        provided: String?,
        harness: ManagerHarness
    ) -> String {
        VisitorContextManager.resolveVisitorId(
            provided: provided,
            secureStore: harness.secureStore,
            keyValueStore: harness.keyValueStore,
            logger: harness.logger
        )
    }

    // MARK: Explicit-ID path

    @Test("An explicit non-empty ID is returned as-is with zero store access")
    func explicitIdReturnsAsIs() {
        let harness = makeManager()

        let result = resolve(provided: "user-abc", harness: harness)

        #expect(result == "user-abc")
        #expect(harness.secureStore.readCallCount == 0, "explicit ID must not read the Keychain")
        #expect(harness.secureStore.writeCallCount == 0, "explicit ID must not write the Keychain")
        #expect(harness.keyValueStore.writeCallCount == 0, "explicit ID must not write the mirror")
    }

    @Test("Two explicit IDs resolve to two distinct, independent results")
    func multipleContextsAreIndependent() {
        let resultA = resolve(provided: "A", harness: makeManager())
        let resultB = resolve(provided: "B", harness: makeManager())

        #expect(resultA == "A")
        #expect(resultB == "B")
        #expect(resultA != resultB)
    }

    // MARK: Generation paths (parameterized)

    /// The two distinct conditions under which `resolveVisitorId` must GENERATE a fresh UUID:
    /// genuinely empty stores, and a corrupted (empty-string) Keychain entry. Both are covered
    /// by one parameterized body so the "result is a valid UUID, no throw" assertion is written
    /// once. A named struct (not a tuple) keeps the `large_tuple` lint rule satisfied.
    struct GenerationCase: Sendable {
        let label: String
        let secureReadBehavior: MockSecureStore.ReadBehavior
    }

    static let generationCases: [GenerationCase] = [
        GenerationCase(label: "empty stores", secureReadBehavior: .normal),
        GenerationCase(label: "corrupted empty Keychain", secureReadBehavior: .empty)
    ]

    @Test("Generation paths yield a fresh uppercase UUID without throwing", arguments: generationCases)
    func generationYieldsValidUUID(testCase: GenerationCase) {
        let harness = makeManager(secureReadBehavior: testCase.secureReadBehavior)

        let result = resolve(provided: nil, harness: harness)

        expectIsGeneratedUUID(result, "\(testCase.label): expected a fresh UUID, got \(result)")
    }

    @Test("Empty stores: the new UUID is persisted to both the Keychain and the mirror")
    func nilIdPersistsOnFirstCall() {
        let harness = makeManager()

        let result = resolve(provided: nil, harness: harness)

        #expect(harness.secureStore.writeCallCount == 1, "the new UUID must be written to the Keychain once")
        #expect(harness.secureStore.value(forKey: StorageKeys.visitorId) == result)
        #expect(
            harness.keyValueStore.string(forKey: StorageKeys.visitorIdMirror) == result,
            "the new UUID must be mirrored to the key/value store"
        )
    }

    @Test("Corrupted (empty) Keychain generates a new UUID without throwing")
    func corruptedKeychainGeneratesNewUUID() {
        let harness = makeManager(secureReadBehavior: .empty)

        let result = resolve(provided: nil, harness: harness)

        expectIsGeneratedUUID(result, "an empty Keychain entry must be treated as a miss")
    }

    // MARK: Read-back paths

    @Test("A UUID already in the Keychain is returned verbatim with no write")
    func nilIdReadsFromKeychainOnSecondCall() {
        let seeded = "11111111-2222-3333-4444-555555555555"
        let harness = makeManager(keychainValue: seeded)

        let result = resolve(provided: nil, harness: harness)

        #expect(result == seeded)
        #expect(harness.secureStore.writeCallCount == 0, "an existing Keychain value must not be re-written")
    }

    @Test("Keychain miss falls back to the mirror and backfills the Keychain")
    func keychainFallsBackToUserDefaults() {
        let mirrored = "66666666-7777-8888-9999-AAAAAAAAAAAA"
        let harness = makeManager(userDefaultsValue: mirrored, secureReadBehavior: .miss)

        let result = resolve(provided: nil, harness: harness)

        #expect(result == mirrored, "the mirror value must be returned when the Keychain misses")
        #expect(harness.secureStore.writeCallCount == 1, "the mirror value must be backfilled into the Keychain")
        #expect(
            harness.secureStore.value(forKey: StorageKeys.visitorId) == mirrored,
            "after backfill the Keychain must hold the mirror value"
        )
    }

    // MARK: Failure path

    @Test("A throwing Keychain read is swallowed, a WARN is logged, and a fresh UUID is generated")
    func throwingKeychainGeneratesNewUUID() {
        let injected = NSError(domain: "Keychain", code: -25_300)
        let harness = makeManager(secureReadBehavior: .throwing(injected))

        let result = resolve(provided: nil, harness: harness)

        expectIsGeneratedUUID(result, "a throwing Keychain read must fall back to a generated UUID")
        let warnings = harness.logger
            .entries(type: "VisitorContextManager")
            .filter { $0.level == .warn }
        #expect(!warnings.isEmpty, "a storage error must emit a [WARN] log line")
    }
}
