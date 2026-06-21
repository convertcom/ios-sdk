// Tests/ConvertSwiftSDKTests/ConvertContextRunExperiencesTests.swift
// `@testable` import (the established pattern — see `ConvertSwiftSDKTests.swift` / `ConvertContextTests.swift`
// headers): this suite reaches the SDK's INTERNAL surface so a separate test target can see `internal`
// members. It lives in its OWN file (not appended to `ConvertContextTests.swift`) because that file is
// already ~336 lines and adding this suite would push it over SwiftLint's `file_length` (400) limit —
// a new file is cleaner than compressing the existing one. The multi-experience FIXTURE this suite
// builds on (`makeMultiExperienceConfig`) lives in `Support/TestFixtures.swift` alongside the
// single-experience `makeExperienceConfig` it twins.
//
// ── Story 3.5 (Epic 3) RED phase ────────────────────────────────────────────────────────────────────
// Asserts the REAL behaviour the GREEN step must produce when it replaces the
// `runExperiences(enableTracking:)` STUB (which returns `[]` UNCONDITIONALLY) with a wired
// `ExperienceManager.selectVariations(...)` delegation. The contract GREEN implements:
//   * read the config snapshot from the SDK's `ConfigStore`; a `nil` snapshot (pre-ready / no config)
//     → return `[]` WITHOUT touching the manager;
//   * otherwise delegate to `ExperienceManager.selectVariations(in:visitorId:accountId:projectId:
//     attributes:locationProperties:enableTracking:)`, returning its `[Variation]` verbatim — which is
//     every eligible experience's bucketed variation in CONFIG ORDER; never throw.
//
// Three of these tests FAIL against the current stub — that compile-passing, runtime-failing state is
// the correct RED signal for a WIRING task (cleaner than a compile-fail): the suite calls only the
// EXISTING public surface (`ConvertSwiftSDK(...)`, `ready()`, `createContext`, `runExperiences`) plus the
// new `makeMultiExperienceConfig` fixture, so it COMPILES today; the assertions on a non-empty,
// concretely-ordered `[Variation]` are what the `[]`-returning stub cannot satisfy.
//   * `runExperiencesPreReadyReturnsEmpty` — PASSES today (the stub returns `[]`, which is ALSO the
//     wired no-snapshot answer), pinning the degraded path across the wiring change.
//   * `runExperiencesReadyReturnsAllVariations` + `runExperiencesPreservesConfigOrder` +
//     `runExperiencesDefaultArgMatchesExplicitTrue` — FAIL today (stub returns `[]` ⇒ `count == 3`,
//     the ordered-keys equality, and the default-vs-explicit equivalence all fail); they pass once the
//     real `ExperienceManager` delegation is wired.
//
// ── Why RETURN VALUES only (no enqueue-count asserts) ────────────────────────────────────────────────
// `ConvertSwiftSDK` wires its OWN internal `EventSink` inside `ExperienceManager.makeDefault(...)`; it is
// NOT injectable through the `createContext` seam (documented in `ConvertContextTests.swift` ~L246-249
// for the `runExperience` wiring suite). So this suite asserts RETURN VALUES only — count, config
// order, the pre-ready-empty degraded path, and default-argument equivalence. The exactly-once enqueue
// (and its tracking-off suppression) is covered at the `ExperienceManager` level by a separate suite;
// THIS suite owns the public-API `runExperiences` RETURN-VALUE contract.
import Testing
import Foundation
@testable import ConvertSwiftSDK

// MARK: - ConvertContext runExperiences wiring (Story 3.5)

@Suite("ConvertContext runExperiences wiring")
@MainActor
struct ConvertContextRunExperiencesTests {
    /// How many 100%-traffic experiences the multi-experience fixture carries for the ready-path tests —
    /// declared once so the fixture build, the count assertion, and the expected-order array never
    /// re-spell the literal (SonarQube 3% new-duplicated-lines gate).
    private static let experienceCount = 3

    /// The config-order experience keys the `count`-experience fixture emits (`"exp-1".."exp-3"`) —
    /// the deterministic order the wired `runExperiences()` must preserve. Derived from
    /// `experienceCount` (single source) so the count and the order assertion can never drift apart,
    /// and shared by the order + default-equivalence tests rather than each inlining the literal array.
    private static let expectedKeys = (1...experienceCount).map { "exp-\($0)" }

    /// Builds a READY off-network SDK whose live config carries `count` 100%-traffic no-audience
    /// experiences, then awaits `ready()` so a subsequent `createContext().runExperiences()` sees a
    /// NON-`nil` snapshot and buckets EVERY experience through the wired manager. Centralised so the
    /// ready-path tests never copy-paste the provider build + `ready()` await (SonarQube 3% gate).
    /// Mirrors `ConvertContextRunExperienceTests.makeReadySDK`: a `MockConfigProvider` canned
    /// `(cached: nil, live: <multi-experience config>)` keeps the SDK off the network and resolves
    /// `ready()` non-degraded with that snapshot.
    private func makeReadySDK(count: Int = Self.experienceCount) async throws -> ConvertSwiftSDK {
        let sdk = ConvertSwiftSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(
                cached: nil,
                live: try makeMultiExperienceConfig(count: count)
            ),
            // Test isolation (bd-ilx): inject a FRESH in-memory `DecisionStore` over a `MockFileStore` so
            // each SDK gets its own sticky-decision state. The default store wires a real on-disk
            // `ApplicationSupportFileStore` at a process-shared path; this factory buckets the
            // `acc-run`/`proj-run`/`user-1` sticky key, mapping experience `exp-1` → `var-1`, which would
            // otherwise PERSIST to that shared file and hydrate into the sibling
            // `ConvertContextRunExperienceTests.makeReadySDK` run (same key, same `exp-1`, but variation
            // `v1`) — overriding its fresh bucketing. A per-call `MockFileStore` keeps these decisions
            // in-process so neither suite leaks into the other. Mirrors the injection precedent across the
            // `ConvertContext*`/conversion/segmentation suites.
            decisionStore: DecisionStore(logger: MockLogger(), fileStore: MockFileStore())
        )
        try await sdk.ready()
        return sdk
    }

    /// AC (degraded): a context whose SDK has NO usable config snapshot resolves `runExperiences()` to
    /// `[]` without throwing. Built with `MockConfigProvider.ungated(cached: nil, live: nil)` — the SDK
    /// resolves degraded with a `nil` snapshot, so the wired `runExperiences` short-circuits on the
    /// absent snapshot BEFORE reaching the manager (and the current stub also returns `[]`). This
    /// therefore PASSES both today and after wiring — it pins the no-config degraded path across the
    /// change. Built WITHOUT `await ready()` (mirroring `runExperiencePreReadyReturnsNil`): the point is
    /// the missing snapshot, asserted on a pre-ready context.
    @Test("runExperiences on a config-less (pre-ready / degraded) context returns [] and does not throw")
    func runExperiencesPreReadyReturnsEmpty() async throws {
        let sdk = ConvertSwiftSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(cached: nil, live: nil)
        )
        let context = sdk.createContext()
        #expect(await context.runExperiences().isEmpty)
    }

    /// RED driver (AC1): a READY SDK holding `experienceCount` 100%-traffic no-audience experiences
    /// buckets a context into EVERY one, so `runExperiences()` returns EXACTLY `experienceCount`
    /// variations (each experience's sole full-traffic variation covers the whole bucket space ⇒
    /// buckets for any visitor). The current stub returns `[]`, so `count == 3` FAILS today — the
    /// expected RED signal; the real `ExperienceManager` delegation makes it pass.
    @Test("runExperiences on a ready SDK returns one variation per eligible experience")
    func runExperiencesReadyReturnsAllVariations() async throws {
        let sdk = try await makeReadySDK()
        let result = await sdk.createContext(visitorId: "user-1").runExperiences()
        #expect(result.count == Self.experienceCount)
    }

    /// RED driver (AC1 — order): the result order MATCHES config order — `result.map { $0.experienceKey }`
    /// equals `["exp-1", "exp-2", "exp-3"]` (the fixture's deterministic order). `selectVariations`
    /// iterates `config.rawExperiences` in order and appends each bucketed variation, so the public API
    /// must surface that order. The stub returns `[]`, so the mapped keys are `[]` and the equality
    /// FAILS today — the expected RED signal until the delegation is wired.
    @Test("runExperiences result order matches config order")
    func runExperiencesPreservesConfigOrder() async throws {
        let sdk = try await makeReadySDK()
        let result = await sdk.createContext(visitorId: "user-1").runExperiences()
        #expect(result.map { $0.experienceKey } == Self.expectedKeys)
    }

    /// RED driver (AC2 — default-argument equivalence): on a READY SDK, `runExperiences()` and
    /// `runExperiences(enableTracking: true)` return the SAME variations — same count AND same
    /// `experienceKey`s in the same order — validating the `enableTracking: Bool = true` default
    /// WITHOUT observing enqueues (not injectable through this seam). `Variation` is `Codable`/`Sendable`
    /// but NOT `Equatable`, so equality is asserted on `.map { $0.experienceKey }` + `.count`, not on
    /// `[Variation]` directly. Both calls require the NON-EMPTY wired result (`count == experienceCount`):
    /// the stub returns `[]` for both, so that precondition FAILS today — the expected RED signal (a
    /// trivially-equal `[] == []` would NOT exercise the default, so the assertion demands the wired
    /// count).
    @Test("runExperiences() and runExperiences(enableTracking: true) return the same variations")
    func runExperiencesDefaultArgMatchesExplicitTrue() async throws {
        let context = try await makeReadySDK().createContext(visitorId: "user-1")

        let defaulted = await context.runExperiences()
        let explicit = await context.runExperiences(enableTracking: true)

        #expect(defaulted.count == Self.experienceCount, "the default-arg call must return the wired set")
        #expect(explicit.count == Self.experienceCount, "the explicit-true call must return the wired set")
        #expect(defaulted.map { $0.experienceKey } == explicit.map { $0.experienceKey })
    }
}
