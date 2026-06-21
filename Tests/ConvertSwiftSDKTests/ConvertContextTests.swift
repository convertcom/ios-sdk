// Tests/ConvertSwiftSDKTests/ConvertContextTests.swift
// `@testable` import (the established pattern — see ConvertSwiftSDKTests.swift header): these
// suites reach the SDK's INTERNAL surface, so a separate test target can see `internal`
// members. This suite covers Story 2.4 tracking-toggle scaffolding (readiness decision D4)
// and Story 5.4 global gate suppression:
//
//   * Story 2.4 (D4): the `ConvertContextTrackingToggleTests` suite asserts that disabled
//     tracking leaves decisioning stubs returning their degraded values — confirming the gate
//     does not alter stub behavior. The sync accessors (`trackingEnabled()` /
//     `networkTrackingEnabled`) scaffolded in D4 were SUPERSEDED by the async
//     `isTrackingEnabled()` gate in Story 5.6 (PR #34) and removed there; coverage of the
//     init-time flag polarity is provided by
//     `ConvertSwiftSDKTrackingToggleTests.neverSetReturnsInitValue` (parameterized [true,false]).
//   * Story 5.4: the `ConvertContextNetworkTrackingTests` suite asserts the global gate
//     suppresses event delivery to the ``EventSink`` while leaving decisioning intact. The
//     production gate is the async `await sdk.isTrackingEnabled()` (Story 5.6).
//
// `file_length` is disabled file-wide (a single named rule — NOT `disable all`): Story 5.4 appended the
// `ConvertContext networkTracking suppression` suite here (per the story's "add to the existing
// ConvertContextTests" directive — the global-gate verification belongs beside the tracking-toggle
// suite it extends), which pushed this DocC-heavy file past the 400-line default. Splitting it out would
// scatter the toggle-hook ↔ global-gate coverage for no readability gain; every other rule — and the
// 400-line gate on every OTHER file — stays enforced. Mirrors the file-wide `file_length` disable
// convention in `MockCorePorts.swift` / `EventQueueTests.swift` / `Support/TestFixtures.swift`.
// swiftlint:disable file_length
import Testing
import Foundation
@testable import ConvertSwiftSDK

// MARK: - ConvertContext tracking toggle

@Suite("ConvertContext tracking toggle")
struct ConvertContextTrackingToggleTests {
    /// Single construction site for the system-under-test, reused by every test so the
    /// `ConvertConfiguration` build + off-network SDK wiring + `createContext()` is never
    /// copy-pasted per case (SonarQube 3% new-duplicated-lines gate). The injected provider is
    /// `ungated(cached: nil, live: nil)` — the SDK touches NO network and its detached config
    /// load resolves degraded in the background; that is irrelevant here because
    /// `configuration.networkTracking` is set SYNCHRONOUSLY at init, so no `ready()` await is
    /// required (the context is usable pre-ready). Only `networkTracking` varies between cases,
    /// so it is the lone parameter.
    ///
    /// `@MainActor` so callers may drive it from `MainActor`-affined `@Test` bodies; the SDK's
    /// internal init is non-async (the handle is built synchronously), so the factory does not
    /// `await`.
    @MainActor
    private func makeContext(networkTracking: Bool) -> ConvertContext {
        let configuration = ConvertConfiguration(sdkKey: "test-key", networkTracking: networkTracking)
        let sdk = ConvertSwiftSDK(
            configuration: configuration,
            configProvider: MockConfigProvider.ungated(cached: nil, live: nil)
        )
        return sdk.createContext()
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

/// Story 3.1 (Epic 3) RED phase: asserts that ``ConvertSwiftSDK/createContext(visitorId:attributes:)``
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
///   * `secureStore:` / `keyValueStore:` (+ a canonical `decisionStore`) params on `ConvertSwiftSDK`'s
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
    /// `ConvertConfiguration` build + `ConvertSwiftSDK(...)` wiring is never copy-pasted per case
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
    ) -> ConvertSwiftSDK {
        ConvertSwiftSDK(
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

    /// AC9 + Dev Notes ("ConvertSwiftSDK creates one canonical instance injected into every
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
/// EXISTING public surface (`ConvertSwiftSDK(...)`, `ready()`, `createContext`, `runExperience`) plus the
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
/// are deliberately NOT asserted here: ``ConvertSwiftSDK`` wires its own (internal) `EventSink`, not
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
    /// Mirrors `ConvertSwiftSDKTests`' `makeSut`-style off-network construction: a `MockConfigProvider`
    /// canned `(cached: nil, live: <hero config>)` keeps the SDK off the network and resolves
    /// `ready()` non-degraded with that snapshot.
    private func makeReadySDK() async throws -> ConvertSwiftSDK {
        let sdk = ConvertSwiftSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(
                cached: nil,
                live: try makeExperienceConfig(
                    experienceKey: Self.experienceKey,
                    variationId: Self.variationId,
                    variationKey: "control"
                )
            ),
            // Test isolation (bd-ilx): inject a FRESH in-memory `DecisionStore` over a `MockFileStore`
            // so each SDK gets its own sticky-decision state. The default store wires a real on-disk
            // `ApplicationSupportFileStore` at a process-shared path; without this, a sticky decision
            // persisted by a SIBLING suite (`ConvertContextRunExperiencesTests` buckets the SAME
            // `acc-run`/`proj-run`/`user-1` key, mapping experience `exp-1` → `var-1`) hydrates here via
            // `ready()` → `loadFromDisk`, so the sticky short-circuit returns `var-1` and overrides this
            // fixture's fresh `exp-1 → v1` bucketing — failing `variation?.id == "v1"`. A per-call
            // `MockFileStore` keeps every run's decisions in-process. Mirrors the injection precedent in
            // the `ConvertContextNetworkTrackingTests.makeReadySDK` factory below and across the suite.
            decisionStore: DecisionStore(logger: MockLogger(), fileStore: MockFileStore())
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
        let sdk = ConvertSwiftSDK(
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

// MARK: - ConvertContext networkTracking suppression (Story 5.4)

/// Story 5.4 (Epic 5) — the GLOBAL `network.tracking` gate (FR6). The Story 2.4 sync scaffolding
/// (superseded — see Story 5.6 PR #34) merely mirrored the flag; this suite asserts the flag now
/// SUPPRESSES event delivery to the ``EventSink`` while leaving decisioning intact:
///   * AC1 — `networkTracking: false` ⇒ NO entry reaches the sink from either `runExperience` (bucketing)
///     or `trackConversion`, yet the variation is STILL bucketed (decisioning is unaffected — only
///     delivery is gated).
///   * AC2 — the per-call `enableTracking:false` still suppresses the bucketing enqueue with the global
///     flag ON, and a subsequent `trackConversion` still enqueues (the conversion path has no per-call
///     flag — FR23).
///   * AC3 — combined precedence: the bucketing enqueue lands ONLY when BOTH the global flag AND the
///     per-call `enableTracking` are true (`(true,true) → 1`; every other row → 0).
///   * AC4 — re-enabling resumes delivery (modelled as a fresh SDK, since the flag is
///     construction-time-immutable on ``ConvertConfiguration``).
///   * AC5 — sticky-equivalence: with the gate OFF a decision is still WRITTEN and READ back (a second
///     `runExperience` returns the same variation id), proving ``DecisionStore`` writes are upstream of —
///     and unaffected by — the enqueue gate.
///   * AC6 — the suppressed conversion path emits a caller-side DEBUG log (the divergence the shipped
///     `EventQueue`/`BucketingManager` seams drop SILENTLY — this story adds the one conversion-path log),
///     carrying NO SDK key / secret (NFR6).
///
/// RED today: the global flag suppresses NOTHING at an injected sink (`resolveEventSink` returns the
/// `MockEventSink` RAW — the `EventQueue.trackingEnabled` gate is built only on the production path), so
/// `runExperience`/`trackConversion` STILL enqueue with `networkTracking: false` (AC1/AC3/AC4/AC5 fail on
/// non-zero counts), and `trackConversion` emits no DEBUG suppression line (AC6 fails). The GREEN step
/// threads the combined flag into the experience path and guards the two conversion enqueues.
///
/// D5 TRAP (avoided): every count assertion runs over a READY SDK whose live config carries BOTH a
/// 100%-traffic `"hero"` experience AND a `"purchase"` goal (``makeExperienceAndGoalConfig``) — under
/// `live: nil`, `runExperience` short-circuits to `nil` BEFORE any enqueue, so a naive `(true,true)` row
/// would falsely read 0. The injected `MockEventSink` flows to BOTH the bucketing path (via
/// `ExperienceManager.makeDefault`) and the conversion seam, so one sink observes both.
@Suite("ConvertContext networkTracking suppression")
@MainActor
struct ConvertContextNetworkTrackingTests {
    /// The 100%-traffic experience key the fixture buckets every visitor into — declared once so the
    /// fixture build and each `runExperience(_:)` call never re-spell the literal (SonarQube 3% gate).
    private static let experienceKey = "hero"
    /// The sole-variation id that full-traffic experience resolves to (asserted by the sticky case).
    private static let variationId = "v1"
    /// The sole-variation key the fixture carries.
    private static let variationKey = "control"
    /// The goal key the conversion cases convert on.
    private static let goalKey = "purchase"
    /// The wire goal id the fixture's goal carries.
    private static let goalId = "g1"

    /// The fully-wired system-under-test plus the collaborators a case drives and observes. A named
    /// struct (not a large tuple) keeps the `large_tuple` lint rule satisfied. `Sendable` — `ConvertSwiftSDK`
    /// is `Sendable`, `MockEventSink` is an `actor`, `MockLogger` is a `Sendable` final class.
    private struct TrackingSUT: Sendable {
        /// The ready SDK whose config carries the `"hero"` experience + `"purchase"` goal, built with the
        /// `networkTracking` polarity under test and the injected sink / logger.
        let sdk: ConvertSwiftSDK
        /// The sink BOTH the bucketing path and the conversion seam enqueue through; read via
        /// `recordedEvents()` (the gate's observable surface — zero entries ⇒ suppressed).
        let sink: MockEventSink
        /// The structured-log spy; `entries(...)` filters the conversion-path DEBUG suppression line.
        let logger: MockLogger
    }

    /// One row of the AC3 combined-precedence matrix: the two input flags plus the expected bucketing
    /// enqueue count. A named struct (not a 3-tuple) keeps the `large_tuple` lint rule (max 2 members)
    /// satisfied, matching the codebase's `ParityVector` / `WeightedVariation` precedent. Internal (not
    /// `private`) so the `@Test` method that takes it as a parameter need not itself be `private` — the
    /// same access-level alignment `HashParityTests.ParityVector` uses for its parameterized parity test.
    struct MatrixRow: Sendable {
        let networkTracking: Bool
        let enableTracking: Bool
        let expectedEnqueues: Int
    }

    /// Builds a READY off-network SDK over the combined experience+goal fixture with the given
    /// `networkTracking` flag, an injected `MockEventSink` (so enqueues on BOTH paths are observable),
    /// `MockLogger` (so the AC6 suppression DEBUG is observable), and a FRESH in-memory `DecisionStore`
    /// over a `MockFileStore`, then awaits `ready()`. THE single construction site for every case so the
    /// provider build + `ready()` await is never copy-pasted (SonarQube 3% gate); only `networkTracking`
    /// varies. Mirrors the injection precedent in `GoalDeduplicationTests.makeReadySDK` (the sink threads
    /// to the bucketing enqueue via `ConvertSwiftSDK` → `ExperienceManager.makeDefault` → `BucketingManager`).
    ///
    /// The injected per-SUT `DecisionStore` is ISOLATION-CRITICAL, not incidental: the default store wires
    /// a real on-disk `ApplicationSupportFileStore` at a process-shared path, so without this a sticky
    /// decision (or goal-dedup mark) persisted by one test hydrates in another's `ready()` → `loadFromDisk`,
    /// making `runExperience` take the sticky short-circuit (no bucket, no enqueue) and `trackConversion`
    /// dedup to a no-op — both enqueue counts would then depend on test order. A fresh `MockFileStore` per
    /// SUT keeps every case's `"user-1"` unbucketed and untriggered, so the counts are deterministic.
    private func makeReadySDK(networkTracking: Bool) async throws -> TrackingSUT {
        let sink = MockEventSink()
        let logger = MockLogger()
        let sdk = ConvertSwiftSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key", networkTracking: networkTracking),
            configProvider: MockConfigProvider.ungated(
                cached: nil,
                live: try makeExperienceAndGoalConfig(
                    experienceKey: Self.experienceKey,
                    variationId: Self.variationId,
                    variationKey: Self.variationKey,
                    goalKey: Self.goalKey,
                    goalId: Self.goalId
                )
            ),
            eventSink: sink,
            logger: logger,
            decisionStore: DecisionStore(logger: MockLogger(), fileStore: MockFileStore())
        )
        try await sdk.ready()
        return TrackingSUT(sdk: sdk, sink: sink, logger: logger)
    }

    /// The conversion-path DEBUG suppression lines `trackConversion` emits when the global gate is off.
    /// Single owner of the filter so the AC6 assertions do not re-inline the `entries(...).filter` chain.
    private func suppressionDebugLines(in logger: MockLogger) -> [MockLogger.LogEntry] {
        logger.entries(type: "ConvertContext", method: "trackConversion")
            .filter { $0.level == .debug && $0.message.contains("suppressed") }
    }

    /// AC1: with the global gate OFF, NEITHER `runExperience` (bucketing) NOR `trackConversion` reaches
    /// the sink — yet the variation is STILL bucketed (decisioning is unaffected; only delivery is gated).
    @Test("networkTracking off suppresses every enqueue while still bucketing the variation")
    func disabledTrackingSuppressesEnqueueButStillBuckets() async throws {
        let sut = try await makeReadySDK(networkTracking: false)
        let context = sut.sdk.createContext(visitorId: "user-1")

        let variation = await context.runExperience(Self.experienceKey)
        await context.trackConversion(Self.goalKey)

        #expect(await sut.sink.recordedEvents().isEmpty, "tracking off must enqueue nothing on either path")
        #expect(variation != nil, "decisioning is unaffected — the variation is still bucketed")
    }

    /// AC2: with the global gate ON, the per-call `enableTracking: false` still suppresses the bucketing
    /// enqueue, and a subsequent `trackConversion` STILL enqueues — the conversion path has no per-call
    /// flag (FR23), so only the bucketing enqueue is withheld.
    @Test("per-call enableTracking off withholds bucketing but a later conversion still enqueues")
    func perCallTrackingOffStillTracksConversion() async throws {
        let sut = try await makeReadySDK(networkTracking: true)
        let context = sut.sdk.createContext(visitorId: "user-1")

        _ = await context.runExperience(Self.experienceKey, enableTracking: false)
        #expect(await sut.sink.recordedEvents().isEmpty, "enableTracking:false withholds the bucketing enqueue")

        await context.trackConversion(Self.goalKey)
        #expect(await sut.sink.recordedEvents().count == 1, "the conversion path has no per-call gate (FR23)")
    }

    /// AC3: combined precedence — the bucketing enqueue lands ONLY when BOTH the global `networkTracking`
    /// AND the per-call `enableTracking` are true. ONE parameterized test over the full 2×2 matrix (rather
    /// than four near-identical bodies) keeps the rows from duplicating the build-then-bucket block
    /// (SonarQube 3% gate). Only `runExperience` runs here (no `trackConversion`), so the sole possible
    /// enqueue is the single bucketing entry: `(true,true) → 1`, every other row → 0.
    @Test(
        "bucketing enqueues only when both the global and per-call tracking flags are true",
        arguments: [
            MatrixRow(networkTracking: false, enableTracking: true, expectedEnqueues: 0),
            MatrixRow(networkTracking: true, enableTracking: false, expectedEnqueues: 0),
            MatrixRow(networkTracking: false, enableTracking: false, expectedEnqueues: 0),
            MatrixRow(networkTracking: true, enableTracking: true, expectedEnqueues: 1)
        ]
    )
    func combinedFlagPrecedence(row: MatrixRow) async throws {
        let sut = try await makeReadySDK(networkTracking: row.networkTracking)
        let context = sut.sdk.createContext(visitorId: "user-1")

        _ = await context.runExperience(Self.experienceKey, enableTracking: row.enableTracking)

        #expect(
            await sut.sink.recordedEvents().count == row.expectedEnqueues,
            "nt=\(row.networkTracking) et=\(row.enableTracking) must enqueue \(row.expectedEnqueues)"
        )
    }

    /// AC4: re-enabling tracking resumes delivery. The flag is construction-time-immutable on
    /// ``ConvertConfiguration`` (a `let`), so "re-enable" is modelled as a FRESH SDK with its own sink —
    /// NOT a mutation of a live flag. The disabled SDK enqueues nothing; the re-enabled one enqueues the
    /// single bucketing entry.
    @Test("re-enabling networkTracking (a fresh SDK) resumes the bucketing enqueue")
    func reEnablingResumesEnqueue() async throws {
        let disabled = try await makeReadySDK(networkTracking: false)
        _ = await disabled.sdk.createContext(visitorId: "user-1").runExperience(Self.experienceKey)
        #expect(await disabled.sink.recordedEvents().isEmpty, "the disabled SDK enqueues nothing")

        let enabled = try await makeReadySDK(networkTracking: true)
        _ = await enabled.sdk.createContext(visitorId: "user-1").runExperience(Self.experienceKey)
        #expect(await enabled.sink.recordedEvents().count == 1, "the re-enabled SDK resumes the enqueue")
    }

    /// AC5 (sticky-equivalence): with the gate OFF a decision is still WRITTEN and READ back — a second
    /// `runExperience` for the same visitor returns the SAME variation id (a sticky hit off the persisted
    /// decision), while the sink stays empty. Proves ``DecisionStore`` writes are upstream of, and
    /// unaffected by, the enqueue gate (AC5 holds structurally even with tracking off).
    @Test("decision is persisted and read back with tracking off (sticky), enqueueing nothing")
    func stickyDecisionPersistsWithTrackingOff() async throws {
        let sut = try await makeReadySDK(networkTracking: false)
        let context = sut.sdk.createContext(visitorId: "user-1")

        let first = await context.runExperience(Self.experienceKey)
        let second = await context.runExperience(Self.experienceKey)

        #expect(first?.id != nil, "the first run must bucket a variation to make stickiness observable")
        #expect(first?.id == second?.id, "the second run is a sticky hit off the persisted decision")
        #expect(await sut.sink.recordedEvents().isEmpty, "the decision persists with no enqueue (gate off)")
    }

    /// AC6: the suppressed conversion path emits a caller-side DEBUG log — the divergence this story
    /// adds (the shipped `EventQueue`/`BucketingManager` seams drop silently; the conversion guard logs
    /// once). Asserts a `.debug` "suppressed" line on `ConvertContext.trackConversion`, AND that the
    /// message leaks NO SDK key / secret (NFR6 — the message is a fixed descriptive tail, never an
    /// interpolated credential).
    @Test("a suppressed conversion emits a DEBUG log carrying no SDK key")
    func suppressedConversionEmitsDebugWithoutSecret() async throws {
        let sut = try await makeReadySDK(networkTracking: false)
        await sut.sdk.createContext(visitorId: "user-1").trackConversion(Self.goalKey)

        let debugLines = suppressionDebugLines(in: sut.logger)
        #expect(!debugLines.isEmpty, "a suppressed conversion must emit a DEBUG suppression line")
        for entry in debugLines {
            #expect(!entry.message.contains("test-key"), "the suppression message must not leak the SDK key")
        }
    }
}
