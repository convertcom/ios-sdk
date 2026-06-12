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
