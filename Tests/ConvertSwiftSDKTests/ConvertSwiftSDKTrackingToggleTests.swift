// Tests/ConvertSwiftSDKTests/ConvertSwiftSDKTrackingToggleTests.swift
//
// Story 5.6 (Epic 5) RED phase: tests for the RUNTIME tracking toggle API added to `ConvertSwiftSDK`.
//
// References the NOT-YET-EXISTING public methods:
//   • `ConvertSwiftSDK.setTrackingEnabled(_ enabled: Bool) async`
//   • `ConvertSwiftSDK.isTrackingEnabled() async -> Bool`
//
// Every `sdk.setTrackingEnabled` / `sdk.isTrackingEnabled` call below fails to compile until
// the GREEN step adds those methods — that compile failure is the correct RED signal for this TDD
// cycle. Every other call site (ConvertSwiftSDK.init, ready(), createContext, runExperience,
// runExperiences, trackConversion) already compiles from Stories 2.2–5.4.
//
// ── Suite shape ───────────────────────────────────────────────────────────────────────────────
// A single `makeReadySDK(networkTracking:)` factory (mirroring the Story 5.4
// `ConvertContextNetworkTrackingTests.makeReadySDK` pattern) is the ONE construction site for the
// SUT. EACH CALL receives a FRESH `MockFileStore`-backed `DecisionStore` — isolation-critical:
// the default store wires a real on-disk `ApplicationSupportFileStore` at a process-shared path;
// without this, a sticky decision or goal-dedup mark persisted by one test hydrates in another's
// `ready()` → `loadFromDisk`, making `runExperience` take the sticky short-circuit (no bucket, no
// enqueue) and making enqueue counts order-dependent. A fresh in-memory store per SUT keeps every
// "user-1" unbucketed and untriggered.
//
// ── Avoiding the sticky-masking trap in AC2 ───────────────────────────────────────────────────
// In the re-enable/no-replay test (AC2), the disabled window runs `runExperience(experienceKey)`
// for "user-1", which still WRITES the sticky decision (AC4 proves this). When tracking is
// re-enabled on the SAME sdk, a second `runExperience(experienceKey)` for the SAME visitor takes
// the sticky short-circuit — the `ExperienceManager` returns the persisted variation WITHOUT
// running through the bucketing enqueue site — so the count would not increase either, masking
// whether the gate re-opened. The fix: use a SECOND, FRESH sdk+sink (with its OWN fresh
// `DecisionStore`) for the post-re-enable events, isolating the two windows cleanly.
//
// ── SonarQube 3% new_duplicated_lines_density gate ───────────────────────────────────────────
// `makeReadySDK` is the SINGLE construction site; all private constants are declared ONCE.
// `@Test(arguments:)` handles the `isTrackingEnabled` read-back cases (AC3) and the dedup/sticky
// cases (AC4) to avoid per-case copy-paste. No wall-clock assertions (NFR21).
//
// Imports: `Testing` (swift-testing — NO XCTest); `Foundation` (for `Data`).
// `@testable import ConvertSwiftSDK` reaches `internal` init seams (MockFileStore, DecisionStore
// injection). `MockEventSink`, `MockLogger`, `MockConfigProvider`, `MockFileStore`, and `MockLogger`
// are reused from `Tests/ConvertSwiftSDKTests/Support/MockPorts.swift` — NOT redeclared here.
import Testing
import Foundation
@testable import ConvertSwiftSDK

// MARK: - Runtime Tracking Toggle (Story 5.6)

/// Story 5.6 (Epic 5) RED-phase test suite for `ConvertSwiftSDK.setTrackingEnabled(_:)` /
/// `isTrackingEnabled()`. Every reference to those two methods below is expected to fail
/// compilation until the GREEN step introduces the actor-backed flag and the two public async
/// methods to `ConvertSwiftSDK`. All other surface — `ready()`, `createContext`, `runExperience`,
/// `runExperiences`, `trackConversion`, `MockEventSink.recordedEvents()` — already compiles.
///
/// The suite name mirrors the Android sibling and the story title: "SDK-Level Runtime Tracking
/// Toggle".
@Suite("SDK-Level Runtime Tracking Toggle")
@MainActor
struct ConvertSwiftSDKTrackingToggleTests {

    // MARK: - Shared literal declarations (one owner → SonarQube gate safe)

    /// The 100%-traffic experience key used across all test cases — declared ONCE (SonarQube 3%
    /// new-duplicated-lines gate; CPD is token-based, so the shared constant — not renamed locals —
    /// holds the diff under it).
    private static let experienceKey = "hero"
    /// The sole-variation id the 100%-traffic fixture buckets every visitor into.
    private static let variationId = "v1"
    /// The sole-variation key the fixture carries.
    private static let variationKey = "control"
    /// The goal key the conversion cases convert on.
    private static let goalKey = "purchase"
    /// The wire goal id the fixture's goal carries.
    private static let goalId = "g1"

    // MARK: - SUT struct

    /// The fully-wired system-under-test plus the collaborator a test drives and observes. A named
    /// struct (not a 2-tuple) keeps the `large_tuple` lint rule satisfied and mirrors the Story 5.4
    /// `TrackingSUT` shape. `Sendable` — `ConvertSwiftSDK` is `Sendable`; `MockEventSink` is an `actor`.
    struct ToggleSUT: Sendable {
        /// The ready SDK, initialized with the given `networkTracking` flag and injected with `sink`.
        let sdk: ConvertSwiftSDK
        /// The sink BOTH the bucketing path and the conversion seam enqueue through. Observe via
        /// `recordedEvents()` (zero entries ⇒ suppressed by the runtime toggle or init flag).
        let sink: MockEventSink
    }

    // MARK: - Factory

    /// Builds a READY off-network SDK over the combined experience+goal fixture with the given
    /// `networkTracking` init flag, an injected `MockEventSink` (so both bucketing and conversion
    /// enqueues are observable), and a FRESH in-memory `DecisionStore` over a `MockFileStore` (the
    /// isolation-critical per-SUT store described in the file header), then awaits `ready()`.
    ///
    /// THE single construction site for all four AC test cases — the provider build + `ready()` await
    /// is NEVER copy-pasted (SonarQube 3% gate). Only `networkTracking` varies. Mirrors the
    /// `ConvertContextNetworkTrackingTests.makeReadySDK(networkTracking:)` factory in
    /// `ConvertContextTests.swift` exactly; the two factories are structural twins for the two stories.
    private func makeReadySDK(networkTracking: Bool) async throws -> ToggleSUT {
        let sink = MockEventSink()
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
            decisionStore: DecisionStore(logger: MockLogger(), fileStore: MockFileStore())
        )
        try await sdk.ready()
        return ToggleSUT(sdk: sdk, sink: sink)
    }

    // MARK: - AC1: off→suppress

    /// AC1 — Construct with `networkTracking: true`, then call `setTrackingEnabled(false)` at
    /// runtime. Invoke `runExperience`, `runExperiences`, and `trackConversion`. Assert the sink
    /// records ZERO enqueues across all three paths, while the returned variation is non-nil
    /// (decisioning is unaffected — only delivery is gated). The init flag is `true` to prove the
    /// RUNTIME flip — not the init flag — caused suppression (if the init flag caused it, the 5.4
    /// suite would already cover it; this is a distinct story).
    @Test("setTrackingEnabled(false) suppresses ALL enqueue across runExperience, runExperiences, and trackConversion")
    func runtimeDisableSuppressesAllEnqueue() async throws {
        let sut = try await makeReadySDK(networkTracking: true)
        // Runtime flip — the new API (RED: does not exist yet)
        await sut.sdk.setTrackingEnabled(false)

        let context = sut.sdk.createContext(visitorId: "user-1")

        let variation = await context.runExperience(Self.experienceKey)
        _ = await context.runExperiences()
        await context.trackConversion(Self.goalKey)

        #expect(
            await sut.sink.recordedEvents().isEmpty,
            "runtime setTrackingEnabled(false) must suppress every enqueue on ALL three paths"
        )
        #expect(
            variation != nil,
            "decisioning is unaffected — the variation must still be bucketed with tracking off"
        )
    }

    // MARK: - AC2: on→enqueue + re-enable→no-replay

    /// AC2 — Construct with `networkTracking: true`. Disable at runtime, produce events (and confirm
    /// they are suppressed in the first window). Then construct a SECOND fresh SDK+sink (its own fresh
    /// `DecisionStore` avoids the sticky short-circuit trap — see file header), re-enable by default
    /// (`networkTracking: true`, no set call needed for the second SDK), and produce NEW events.
    /// Assert: nothing was enqueued during the disabled window; after the conceptual re-enable (second
    /// fresh SDK), new events enqueue; suppressed events from the first window are never replayed.
    ///
    /// NOTE: "re-enable" in this test is modelled as a FRESH SDK with `networkTracking: true` because
    /// the GREEN step's `setTrackingEnabled(true)` operates on a live instance. The no-replay contract
    /// is the key assertion: the first-window events must never appear in ANY sink. To separately
    /// assert the SDK-level re-enable on a LIVE instance (which requires the GREEN `setTrackingEnabled`
    /// to exist), see the secondary `runtimeReEnableOnLiveSDK` test below.
    @Test("disabled-window events are never enqueued; re-enabled window sees new events only")
    func disabledWindowSuppressedAndReEnableSeesOnlyNewEvents() async throws {
        // ── DISABLED WINDOW ─────────────────────────────────────────────────────────────────────
        let disabled = try await makeReadySDK(networkTracking: true)
        await disabled.sdk.setTrackingEnabled(false)

        let disabledCtx = disabled.sdk.createContext(visitorId: "user-disabled")
        _ = await disabledCtx.runExperience(Self.experienceKey)
        await disabledCtx.trackConversion(Self.goalKey)

        let disabledCount = await disabled.sink.recordedEvents().count
        #expect(disabledCount == 0, "disabled window must produce 0 enqueues")

        // ── RE-ENABLED WINDOW (fresh SDK+sink — isolated from disabled window and its sticky state)
        let enabled = try await makeReadySDK(networkTracking: true)
        // No `setTrackingEnabled` call: the SDK starts enabled (networkTracking: true is the init flag).
        // The GREEN `setTrackingEnabled(true)` on the previously-disabled SDK would also work but
        // requires the live API; this uses the construction seam to prove the gate re-opens.

        let enabledCtx = enabled.sdk.createContext(visitorId: "user-enabled")
        _ = await enabledCtx.runExperience(Self.experienceKey)

        let enabledCount = await enabled.sink.recordedEvents().count
        #expect(enabledCount >= 1, "re-enabled (fresh) SDK must enqueue at least the bucketing event")

        // No-replay across instances: the disabled sink stays empty even after the enabled
        // window ran (the suppressed first-window events were never enqueued or replayed).
        #expect(
            await disabled.sink.recordedEvents().isEmpty,
            "disabled sink stays empty after the enabled window — suppressed events were never replayed"
        )
    }

    /// AC2 (live re-enable variant) — On a SINGLE live SDK instance: disable, produce+suppress events,
    /// then call `setTrackingEnabled(true)` to re-open the gate, produce NEW events with a DIFFERENT
    /// visitor (avoids sticky short-circuit — see file header), and confirm the new events enqueue while
    /// the suppressed count remains zero. This is the "same instance" re-enable test; it requires the
    /// GREEN `setTrackingEnabled` method to compile.
    @Test("setTrackingEnabled(true) on a live SDK re-opens the gate without replaying suppressed events")
    func runtimeReEnableOnLiveSDK() async throws {
        let sut = try await makeReadySDK(networkTracking: true)

        // Disable and confirm suppression
        await sut.sdk.setTrackingEnabled(false)
        let ctx1 = sut.sdk.createContext(visitorId: "user-A")
        _ = await ctx1.runExperience(Self.experienceKey)
        await ctx1.trackConversion(Self.goalKey)
        let countDuringDisable = await sut.sink.recordedEvents().count
        #expect(countDuringDisable == 0, "disabled window: zero enqueues")

        // Re-enable (the GREEN API — RED compile-fail driver)
        await sut.sdk.setTrackingEnabled(true)

        // Different visitor to avoid sticky-decision short-circuit (see file header)
        let ctx2 = sut.sdk.createContext(visitorId: "user-B")
        _ = await ctx2.runExperience(Self.experienceKey)

        let countAfterReEnable = await sut.sink.recordedEvents().count
        #expect(
            countAfterReEnable >= 1,
            "after setTrackingEnabled(true) the bucketing enqueue must land (gate re-opened)"
        )
        // No-replay proof: user-B's first runExperience on a fresh visitor enqueues exactly ONE
        // bucketing event. If the suppressed-window events (user-A's runExperience + trackConversion)
        // had been replayed, countAfterReEnable would exceed 1. `== 1` is a strict bound;
        // `countDuringDisable == 0` was already asserted above, so this is NOT a tautology.
        #expect(
            countAfterReEnable == 1,
            "exactly the one post-re-enable bucketing event — suppressed-window events were not replayed"
        )
    }

    // MARK: - AC3: isTrackingEnabled read-back

    /// One row of the `isTrackingEnabled` read-back parameterized test: an action tag plus the
    /// expected read-back value. A named struct keeps the `large_tuple` lint rule satisfied (mirrors
    /// `ConvertContextNetworkTrackingTests.MatrixRow`). `Sendable` — both fields are value types.
    struct ReadBackRow: Sendable {
        /// Human-readable tag for the test output.
        let label: String
        /// The value `isTrackingEnabled()` must return for this row.
        let expected: Bool
    }

    /// AC3 — `isTrackingEnabled()` reflects the most-recently-set runtime value, or the init
    /// `networkTracking` flag if `setTrackingEnabled` was never called. Three cases parameterized over
    /// a `ReadBackRow` array (not three near-identical test bodies — SonarQube 3% gate):
    ///   • after `set(false)` → `false`
    ///   • after `set(true)` → `true`
    ///
    /// The "never-set → returns init value" case is handled by the separate `neverSetReturnsInitValue`
    /// parameterized test below, which iterates over `[true, false]` init flags (two SDKs).
    @Test(
        "isTrackingEnabled() reflects the most-recently-set runtime value",
        arguments: [
            ReadBackRow(label: "set(false) → false", expected: false),
            ReadBackRow(label: "set(true) → true", expected: true)
        ]
    )
    func isTrackingEnabledReflectsRuntimeSet(row: ReadBackRow) async throws {
        let sut = try await makeReadySDK(networkTracking: true)
        // Set to the row's expected value (both false and true are exercised)
        await sut.sdk.setTrackingEnabled(row.expected)
        let readBack = await sut.sdk.isTrackingEnabled()
        #expect(
            readBack == row.expected,
            "\(row.label): isTrackingEnabled() must return \(row.expected)"
        )
    }

    /// AC3 (never-set variant) — When `setTrackingEnabled` is NEVER called, `isTrackingEnabled()`
    /// returns the init `ConvertConfiguration.networkTracking` value. Parameterized over `[true, false]`
    /// (two SDKs with different init flags) so both polarities are covered without copy-paste.
    @Test(
        "isTrackingEnabled() returns the init networkTracking value when setTrackingEnabled was never called",
        arguments: [true, false]
    )
    func neverSetReturnsInitValue(initFlag: Bool) async throws {
        let sut = try await makeReadySDK(networkTracking: initFlag)
        // NO setTrackingEnabled call — the read-back must equal the init flag
        let readBack = await sut.sdk.isTrackingEnabled()
        #expect(
            readBack == initFlag,
            "never-set SDK (networkTracking: \(initFlag)): isTrackingEnabled() must return \(initFlag)"
        )
    }

    // MARK: - AC4: decisions and dedup unaffected

    /// One row of the decisioning-invariants parameterized test: whether tracking is enabled plus
    /// a label. `Sendable` — both fields are value types.
    struct DecisionRow: Sendable {
        let trackingEnabled: Bool
        let label: String
    }

    /// AC4 — With tracking off at runtime, decisioning (sticky variation) and goal dedup are
    /// UNAFFECTED: a second `runExperience` for the same visitor returns the SAME variation id
    /// (sticky decision was still written on the first call), and a repeat `trackConversion` for
    /// the same goal is a dedup no-op (the dedup mark persisted even while the gate was off — the
    /// gate sits AFTER `markGoalTriggeredIfNeeded`). The sink stays EMPTY throughout.
    ///
    /// Parameterized over two rows (tracking on vs off) so the invariant is proved for BOTH states
    /// — proving it holds on the tracking-ON row confirms the fixture itself works (no sticky or
    /// dedup failures independent of the toggle); proving it on the OFF row proves the toggle does
    /// not disturb the decisioning machinery. One parameterized body (not two near-identical ones —
    /// SonarQube 3% gate).
    @Test(
        "sticky decisions and goal-dedup persist regardless of the runtime tracking flag",
        arguments: [
            DecisionRow(trackingEnabled: false, label: "tracking OFF"),
            DecisionRow(trackingEnabled: true, label: "tracking ON")
        ]
    )
    func decisionsAndDedupUnaffectedByToggle(row: DecisionRow) async throws {
        let sut = try await makeReadySDK(networkTracking: true)
        await sut.sdk.setTrackingEnabled(row.trackingEnabled)

        let context = sut.sdk.createContext(visitorId: "user-dedup")

        // ── Sticky decision: first run buckets a variation ───────────────────────────────────
        let first = await context.runExperience(Self.experienceKey)
        #expect(
            first != nil,
            "[\(row.label)] first runExperience must bucket a variation (decisioning unaffected)"
        )

        // ── Sticky decision: second run for same visitor returns SAME variation id ───────────
        let second = await context.runExperience(Self.experienceKey)
        #expect(
            first?.id == second?.id,
            "[\(row.label)] sticky: second runExperience must return the same variation id"
        )

        // ── Goal dedup: first trackConversion marks the goal ─────────────────────────────────
        await context.trackConversion(Self.goalKey)

        // ── Goal dedup: second trackConversion is a no-op (already triggered) ─────────────────
        // The dedup mark was written BEFORE the gate (AC4 / AC8 of Story 5.4 — gate is AFTER
        // markGoalTriggeredIfNeeded). So the second call is a WARN-only no-op in both states.
        await context.trackConversion(Self.goalKey)

        // When tracking is OFF: the sink must be empty (gate suppressed both conversion calls)
        // When tracking is ON: the sink has exactly 1 conversion event (the second was deduped);
        //   the bucketing enqueue from runExperience is also present, so we filter to .conversion
        //   only to prove the dedup no-op precisely.
        if !row.trackingEnabled {
            let eventCount = await sut.sink.recordedEvents().count
            #expect(
                eventCount == 0,
                "[\(row.label)] sink must be empty — gate suppressed all enqueues"
            )
        } else {
            let conversionCount = await sut.sink.recordedEvents().filter { $0.eventType == "conversion" }.count
            #expect(
                conversionCount == 1,
                "[\(row.label)] tracking ON: exactly 1 conversion event (second trackConversion is a dedup no-op)"
            )
        }
    }
}
