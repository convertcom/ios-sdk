// Tests/ConvertSDKTests/ConvertContextTests.swift
// `@testable` import (the established pattern — see ConvertSDKTests.swift header): these
// suites reach the SDK's INTERNAL surface, so a separate test target can see `internal`
// members. This suite asserts the Story 2.4 tracking-toggle HOOK (readiness decision D4):
//
//   * `ConvertSDK.networkTrackingEnabled` — an `internal` accessor exposing
//     `configuration.networkTracking` to same-module readers (the config stays `private`).
//   * `ConvertContext.trackingEnabled()` — the `internal` hook a FUTURE `eventSink.enqueue`
//     call site will guard on (`guard trackingEnabled() else { return }`), wired when
//     Epics 3–4 add the real enqueue. D4 sanctions making the hook real + tested NOW while
//     the stub return values stay UNCHANGED (no decisioning logic invented).
//
// RED phase (TDD): `ConvertContext.trackingEnabled()` and `ConvertSDK.networkTrackingEnabled`
// do NOT exist yet, so every reference below is EXPECTED to fail compilation. That compile-fail
// is the correct outcome of this phase; the GREEN step adds the two accessors. The rest of the
// surface this suite touches — `ConvertSDK(...)`, `createContext()`, `runExperience`,
// `runExperiences` — already compiles from Stories 2.2/2.3.
import Testing
import Foundation
@testable import ConvertSDK

// MARK: - ConvertContext tracking toggle

@Suite("ConvertContext tracking toggle")
struct ConvertContextTrackingToggleTests {
    /// Single construction site for the system-under-test, reused by every test so the
    /// `ConvertConfiguration` build + off-network SDK wiring + `createContext()` is never
    /// copy-pasted per case (SonarQube 3% new-duplicated-lines gate). The injected provider is
    /// `ungated(cached: nil, live: nil)` — the SDK touches NO network and its detached config
    /// load resolves degraded in the background; that is irrelevant here because
    /// `trackingEnabled()` reads `configuration.networkTracking`, which is set SYNCHRONOUSLY at
    /// init, so no `ready()` await is required (the context is usable pre-ready). Only
    /// `networkTracking` varies between cases, so it is the lone parameter.
    ///
    /// `@MainActor` so callers may drive it from `MainActor`-affined `@Test` bodies; the SDK's
    /// internal init is non-async (the handle is built synchronously), so the factory does not
    /// `await`.
    @MainActor
    private func makeContext(networkTracking: Bool) -> ConvertContext {
        let configuration = ConvertConfiguration(sdkKey: "test-key", networkTracking: networkTracking)
        let sdk = ConvertSDK(
            configuration: configuration,
            configProvider: MockConfigProvider.ungated(cached: nil, live: nil)
        )
        return sdk.createContext()
    }

    /// `ConvertContext.trackingEnabled()` MIRRORS `ConvertConfiguration.networkTracking`: the
    /// hook reads the flag through the SDK's `internal networkTrackingEnabled` accessor, so a
    /// context built over a config with `networkTracking == flag` reports `trackingEnabled()
    /// == flag`. Parameterized over both polarities (rather than two near-identical test bodies)
    /// to keep the true/false cases from duplicating the build-context-then-assert block
    /// (SonarQube 3% gate). References the NOT-YET-EXISTING `trackingEnabled()` — the RED driver.
    @MainActor
    @Test("trackingEnabled() reflects the config's networkTracking flag", arguments: [true, false])
    func trackingEnabledReflectsConfig(networkTracking: Bool) async throws {
        let context = makeContext(networkTracking: networkTracking)
        #expect(context.trackingEnabled() == networkTracking)
    }

    /// With tracking OFF (`networkTracking: false`) the decisioning STUBS are UNCHANGED:
    /// `runExperience` still returns `nil` and `runExperiences` still returns `[]`. This proves
    /// the toggle hook does not alter stub behavior (D4 — no decisioning logic invented; the
    /// stub contract is preserved with tracking off) and documents that ENQUEUE SUPPRESSION is
    /// deferred: the real AC8 assertion (`MockEventSink.enqueueCallCount == 0` when tracking is
    /// off) cannot be written until `ConvertContext` gains a real `eventSink.enqueue` call site
    /// in Epics 3–4 (story Task 4.5 sanctions deferring it). Today there is no enqueue to
    /// suppress, so the toggle is asserted via the accessor (above) and the stub returns (here).
    @MainActor
    @Test("disabled tracking leaves the decisioning stubs returning their degraded values")
    func disabledTrackingStubStillReturnsDegraded() async throws {
        let context = makeContext(networkTracking: false)
        #expect(await context.runExperience("any") == nil)
        #expect(await context.runExperiences().isEmpty)
    }
}

// MARK: - ConvertContext Visitor Identity

/// Story 3.1 (Epic 3) RED phase: asserts that ``ConvertSDK/createContext(visitorId:attributes:)``
/// resolves a visitor ID through ``VisitorContextManager`` (honouring an explicit ID, else reading
/// the injected stores, else generating + persisting a UUID), coerces the loosely-typed `attributes`
/// into the closed ``ConvertValue`` set (dropping unsupported values), and injects ONE canonical
/// ``DecisionStore`` into every context.
///
/// NONE of the surface this suite touches exists yet, so every reference is EXPECTED to fail
/// compilation — that compile-fail is the correct outcome of the RED phase. The GREEN step ADDS:
///   * `ConvertContext.visitorId: String`, `ConvertContext.attributes: [String: Any]` (reconstructed
///     from private `[String: ConvertValue]` storage), and `internal ConvertContext.decisionStore`,
///     plus the additive `init(sdk:visitorId:attributes:decisionStore:)`.
///   * `secureStore:` / `keyValueStore:` (+ a canonical `decisionStore`) params on `ConvertSDK`'s
///     internal test-seam init, with `createContext` calling `VisitorContextManager.resolveVisitorId`.
/// The existing `ConvertContext tracking toggle` suite above already compiles from Stories 2.2–2.4
/// and is intentionally left untouched.
@Suite("ConvertContext Visitor Identity")
@MainActor
struct ConvertContextVisitorIdentityTests {
    /// The canonical UUID shape `UUID().uuidString` emits — upper-case hex, 8-4-4-4-12. The
    /// generated-ID test matches `visitorId` against this so "an empty store → a real UUID" is
    /// asserted on FORMAT, not on a specific (non-deterministic) value.
    private static let uuidPattern =
        "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"

    /// Single construction site for the off-network SDK, reused by every test so the
    /// `ConvertConfiguration` build + `ConvertSDK(...)` wiring is never copy-pasted per case
    /// (SonarQube 3% new-duplicated-lines gate). The config provider is `ungated(cached: nil,
    /// live: nil)` — no network, the detached load resolves degraded in the background — which is
    /// irrelevant here because `createContext` is synchronous and usable pre-`ready()`. The two
    /// stores are PARAMETERS (defaulting to fresh empty mocks) so a test that needs to read a
    /// call-counter injects its own instance and inspects it afterwards; tests that only care about
    /// the returned context take the defaults.
    ///
    /// `@MainActor` (matching the toggle suite) so `@Test` bodies may drive it directly; the SDK's
    /// internal init is synchronous, so the factory does not `await`.
    private func makeSDK(
        secureStore: MockSecureStore = MockSecureStore(),
        keyValueStore: MockKeyValueStore = MockKeyValueStore()
    ) -> ConvertSDK {
        ConvertSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(cached: nil, live: nil),
            secureStore: secureStore,
            keyValueStore: keyValueStore
        )
    }

    /// AC8 baseline: a no-argument `createContext()` returns a usable context with a non-empty
    /// visitor ID (the empty injected stores drive the resolver to generate one).
    @Test("createContext() with no args returns a non-nil context with a non-empty visitorId")
    func createContextNoArgReturnsNonNil() async throws {
        let context = makeSDK().createContext()
        #expect(context.visitorId.isEmpty == false)
    }

    /// With empty stores the resolver generates `UUID().uuidString`, so `visitorId` must match the
    /// canonical 8-4-4-4-12 upper-case-hex UUID shape (AC3 — a real UUID, not a placeholder).
    @Test("createContext() with no args produces a canonical-UUID visitorId")
    func createContextNoArgProducesUUIDFormat() async throws {
        let visitorId = makeSDK().createContext().visitorId
        #expect(
            visitorId.range(of: Self.uuidPattern, options: .regularExpression) != nil,
            "expected a canonical UUID, got \(visitorId)"
        )
    }

    /// An explicit caller-supplied ID is returned VERBATIM (precedence rule 1 — never normalised,
    /// no store access).
    @Test("createContext(visitorId:) uses the supplied id verbatim")
    func createContextWithExplicitIdUsesIt() async throws {
        #expect(makeSDK().createContext(visitorId: "v1").visitorId == "v1")
    }

    /// THE load-bearing assertion (story line 207): `attributes` is readable as `[String: Any]`,
    /// so `attributes["age"] as? Int == 30`. This compiles ONLY if `attributes` is `[String: Any]`
    /// (NOT `[String: ConvertValue]`) — the GREEN step reconstructs the `Any` map from the internal
    /// `ConvertValue` storage via `ConvertValue.anyValue`.
    @Test("createContext(attributes:) preserves a supported scalar attribute")
    func createContextPreservesAttributes() async throws {
        #expect(makeSDK().createContext(attributes: ["age": 30]).attributes["age"] as? Int == 30)
    }

    /// Unsupported attribute values (a nested dictionary, etc.) are DROPPED by the
    /// `ConvertValue.init?(any:)` coercion, while a supported sibling scalar in the same map
    /// SURVIVES — proving the coercion filters per-key rather than rejecting the whole map.
    @Test("createContext(attributes:) drops unsupported values but keeps supported ones")
    func createContextDropsUnsupportedAttributes() async throws {
        let attributes = makeSDK()
            .createContext(attributes: ["age": 30, "nested": ["x": 1]])
            .attributes
        #expect(attributes["age"] as? Int == 30)
        #expect(attributes["nested"] == nil)
    }

    /// AC6: two contexts created with DISTINCT explicit IDs keep those distinct IDs (no shared or
    /// cached identity collapses them).
    @Test("two contexts with distinct explicit ids keep them distinct")
    func twoContextsHaveDistinctExplicitIds() async throws {
        let sdk = makeSDK()
        #expect(sdk.createContext(visitorId: "A").visitorId != sdk.createContext(visitorId: "B").visitorId)
    }

    /// AC8: a context is usable BEFORE `ready()` resolves — `createContext()` is synchronous and
    /// does not wait on config load, so its `visitorId` is non-empty without any `await ready()`.
    @Test("createContext() works before ready() with a non-empty visitorId")
    func createContextBeforeReadyStillWorks() async throws {
        // Deliberately do NOT `await sdk.ready()` — the context must be usable pre-ready.
        let context = makeSDK().createContext()
        #expect(context.visitorId.isEmpty == false)
    }

    /// AC7: a developer-supplied ID is returned verbatim with ZERO Keychain access — so the
    /// injected secure store sees NO write (precedence rule 1: explicit ID, no store touch).
    @Test("explicit visitorId does not write the Keychain")
    func explicitIdDoesNotWriteKeychain() async throws {
        let secureStore = MockSecureStore()
        _ = makeSDK(secureStore: secureStore).createContext(visitorId: "explicit")
        #expect(secureStore.writeCallCount == 0)
    }

    /// AC3: a `nil` ID with empty stores generates a UUID and PERSISTS it to the Keychain, so the
    /// injected secure store observes exactly ONE write.
    @Test("nil visitorId persists a generated UUID to the injected secure store")
    func nilIdPersistsToInjectedStores() async throws {
        let secureStore = MockSecureStore()
        _ = makeSDK(secureStore: secureStore).createContext()
        #expect(secureStore.writeCallCount == 1)
    }

    /// AC9 + Dev Notes ("ConvertSDK creates one canonical instance injected into every
    /// ConvertContext"): every context from the SAME SDK holds the SAME `DecisionStore`. The store
    /// is an `actor` (a reference type), so identity (`===`) proves the canonical-injection
    /// contract — two contexts share ONE instance, not two equal ones.
    @Test("contexts from one SDK share the SDK's canonical decisionStore")
    func createContextHoldsDecisionStore() async throws {
        let sdk = makeSDK()
        #expect(sdk.createContext().decisionStore === sdk.createContext().decisionStore)
    }
}

// MARK: - ConvertContext runExperience wiring (Story 3.4)

/// Story 3.4 (Epic 3) RED phase: asserts the REAL behaviour CX-1 must produce when it replaces the
/// `runExperience(_:enableTracking:)` STUB with a wired ``ExperienceManager`` delegation. The
/// contract CX-1 implements:
///   * read the config snapshot from the SDK's ``ConfigStore``; a `nil` snapshot (pre-ready / no
///     config) → return `nil` WITHOUT touching the manager;
///   * otherwise delegate to an injected `ExperienceManager.selectVariation(forKey:in:visitorId:
///     accountId:projectId:attributes:locationProperties:enableTracking:)`, returning its
///     ``Variation?`` verbatim; never throw.
///
/// Two of these tests FAIL against the current stub — that compile-passing, runtime-failing state is
/// the correct RED signal for a WIRING task (cleaner than a compile-fail): the suite calls only the
/// EXISTING public surface (`ConvertSDK(...)`, `ready()`, `createContext`, `runExperience`) plus the
/// new ``makeExperienceConfig`` fixture, so it COMPILES today; the assertions on a non-`nil`,
/// concretely-identified ``Variation`` are what the nil-returning stub cannot satisfy.
///   * ``runExperiencePreReadyReturnsNil`` — PASSES today (the stub returns `nil`, which is ALSO the
///     wired no-snapshot answer), so it pins the degraded path across the wiring change.
///   * ``runExperienceReadyBucketsVariation`` + ``runExperienceStickyReturnsSameVariation`` — FAIL
///     today (stub returns `nil` ⇒ `v != nil`, `v?.id == "v1"`, and the sticky-equality assertions
///     all fail); they pass once CX-1 wires the real ``ExperienceManager``.
///
/// A 100%-traffic experience keyed `"hero"` (built by ``makeExperienceConfig``) buckets EVERY visitor
/// into its sole variation (weight `100 × 100 == 10000` covers the whole `0..<10000` space), so the
/// resolved variation is deterministically `id == "v1"`, `experienceKey == "hero"` for any visitor —
/// which is why these tests can assert a CONCRETE identity, not just non-`nil`. Event/enqueue counts
/// are deliberately NOT asserted here: ``ConvertSDK`` wires its own (internal) `EventSink`, not
/// injectable through this seam — the exactly-once enqueue is covered at the ``ExperienceManager``
/// level by `ExperienceManagerTests`. This suite owns the runExperience RETURN VALUE (nil vs a
/// concrete ``Variation``) and the sticky-stability contract.
@Suite("ConvertContext runExperience wiring")
@MainActor
struct ConvertContextRunExperienceTests {
    /// The experience key both ready-path tests look up — declared once so the fixture build and the
    /// `runExperience(_:)` call never re-spell the literal (SonarQube 3% new-duplicated-lines gate).
    private static let experienceKey = "hero"
    /// The sole-variation id the 100%-traffic fixture buckets every visitor into; the ready test
    /// asserts the resolved variation carries exactly this id.
    private static let variationId = "v1"

    /// Builds a READY off-network SDK whose live config is the single 100%-traffic `"hero"` experience,
    /// then awaits `ready()` so a subsequent `createContext().runExperience("hero")` sees a NON-`nil`
    /// snapshot and buckets through the wired manager. Centralised so the ready-path tests
    /// (bucketing + sticky) never copy-paste the provider build + `ready()` await (SonarQube 3% gate).
    /// Mirrors `ConvertSDKTests`' `makeSut`-style off-network construction: a `MockConfigProvider`
    /// canned `(cached: nil, live: <hero config>)` keeps the SDK off the network and resolves
    /// `ready()` non-degraded with that snapshot.
    private func makeReadySDK() async throws -> ConvertSDK {
        let sdk = ConvertSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(
                cached: nil,
                live: try makeExperienceConfig(
                    experienceKey: Self.experienceKey,
                    variationId: Self.variationId,
                    variationKey: "control"
                )
            )
        )
        try await sdk.ready()
        return sdk
    }

    /// AC10: a context whose SDK has NO usable config snapshot resolves `runExperience` to `nil`
    /// without throwing. Built with `MockConfigProvider.ungated(cached: nil, live: nil)` — the SDK
    /// resolves `ready()` DEGRADED with a `nil` snapshot, so the wired `runExperience` short-circuits
    /// on the absent snapshot BEFORE reaching the manager (and the current stub also returns `nil`).
    /// This therefore PASSES both today and after wiring — it pins the no-config degraded path across
    /// the change. `"any"` is deliberately an UNKNOWN key, so even a ready SDK would return `nil` for
    /// it; here the point is the missing snapshot, asserted without an `await ready()`.
    @Test("runExperience on a config-less (pre-ready / degraded) context returns nil and does not throw")
    func runExperiencePreReadyReturnsNil() async throws {
        let sdk = ConvertSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(cached: nil, live: nil)
        )
        let context = sdk.createContext()
        #expect(await context.runExperience("any") == nil)
    }

    /// RED driver (AC1–AC4): a READY SDK holding the 100%-traffic `"hero"` experience buckets a context
    /// into its sole variation, so `runExperience("hero")` returns a NON-`nil` ``Variation`` whose
    /// `experienceKey == "hero"` and `id == "v1"`. The current stub returns `nil`, so all three
    /// assertions FAIL today — the expected RED signal; CX-1's real ``ExperienceManager`` delegation
    /// makes them pass. The variation id is deterministic for ANY visitor (full-traffic single
    /// variation), so a fixed `visitorId` is asserted on a concrete id, not merely non-`nil`.
    @Test("runExperience on a ready 100%-traffic experience returns the bucketed variation")
    func runExperienceReadyBucketsVariation() async throws {
        let sdk = try await makeReadySDK()
        let context = sdk.createContext(visitorId: "user-1")

        let variation = await context.runExperience(Self.experienceKey)

        #expect(variation != nil, "a ready 100%-traffic experience must bucket, not return nil")
        #expect(variation?.experienceKey == Self.experienceKey)
        #expect(variation?.id == Self.variationId)
    }

    /// RED driver (AC5 — sticky): two `runExperience("hero")` calls for the SAME visitor return the
    /// SAME variation id. The first call buckets + persists a decision into the SDK's canonical
    /// ``DecisionStore``; the second is a sticky hit returning the stored variation. Proves stickiness
    /// flows through the FULL wiring (context → manager → shared `DecisionStore`), not just the
    /// manager in isolation. FAILS today: the stub returns `nil` for both calls, so both unwrapped ids
    /// are `nil` and the non-`nil` precondition fails — the expected RED signal until CX-1 wires the
    /// real delegation.
    @Test("runExperience is sticky — a second call returns the same variation id for the same visitor")
    func runExperienceStickyReturnsSameVariation() async throws {
        let sdk = try await makeReadySDK()
        let context = sdk.createContext(visitorId: "user-1")

        let first = await context.runExperience(Self.experienceKey)
        let second = await context.runExperience(Self.experienceKey)

        #expect(first?.id != nil, "the first run must bucket a variation to make stickiness observable")
        #expect(first?.id == second?.id, "a sticky second run must return the same variation id")
    }
}
