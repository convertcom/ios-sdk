// Tests/ConvertSwiftSDKTests/ConversionTrackingTests.swift
// `@testable import ConvertSwiftSDK` (the established pattern — see `ConvertContextTests.swift` /
// `ConvertContextRunExperiencesTests.swift` headers): this suite reaches the SDK's INTERNAL surface so
// a separate test target can see `internal` members. It lives in its OWN file (not appended to
// `ConvertContextTests.swift`, already ~336 lines) so neither file trips SwiftLint's `file_length`
// (400) limit. The goal-carrying FIXTURE (`makeGoalConfig`) + the `conversionData(from:)` read-back
// helper this suite builds on live in `Support/TestFixtures.swift` and `Support/MockPorts.swift`.
//
// ── Story 4.2 (Epic 4) RED phase ─────────────────────────────────────────────────────────────────────
// Asserts the REAL behaviour the GREEN step must produce when it implements
// `ConvertContext.trackConversion(_:goalData:)` (currently a NO-OP STUB) and wires the injection seam
// (currently ABSENT). The contract GREEN implements:
//   * no config snapshot (pre-ready / degraded) → WARN + DROP (no enqueue);
//   * goal key not found in the config → WARN + DROP (no enqueue);
//   * else build `ConversionEventData{goalId: the goal's id, goalData: goalData?.toEntries(),
//     bucketingData: the visitor's current sticky decisions map (`DecisionStore.bucketingDecisions`)
//     or nil}`, enqueue it via the `EventSink` port as a SINGLE `TrackingEventEntry.conversion(data)`,
//     and fire `SystemEvent.conversion`; never throw.
//
// ── Why these tests are RED today ────────────────────────────────────────────────────────────────────
// The injection seam does not exist: `ConvertSwiftSDK.init` has NO `eventSink:` / `logger:` parameter, so
// the `makeReadySDK` factory's `ConvertSwiftSDK(... eventSink:, logger:)` call FAILS TO COMPILE — that
// compile-fail IS the RED signal for the missing seam (the whole file is RED until GREEN adds the
// parameters). Even once the seam compiles, the behaviour tests FAIL at runtime because `trackConversion`
// is a no-op stub: it enqueues nothing, fires nothing, and logs nothing — so the recorded-events,
// fired-event, and WARN assertions all fail until the real implementation lands.
//
// ── The seam shape the GREEN phase must add (what this suite assumes) ─────────────────────────────────
//   * `ConvertSwiftSDK.init(... eventSink: any EventSink = NoopEventSink(), logger: any Logger = NoopLogger())`
//     — production defaults Noop; a test injects `MockEventSink` / `MockLogger`. (GREEN also makes
//     `NoopEventSink` `public` so it is usable as the cross-module default.)
//   * `ConvertSwiftSDK` stores `eventSink` + `logger` and passes them (with its existing private `eventBus`)
//     into `createContext` → `ConvertContext`.
//   * `ConvertContext` gains stored `eventSink: any EventSink`, `eventBus: EventBus`,
//     `logger: any Logger`, and a real `trackConversion`.
//
// ── SonarQube 3% new-duplicated-lines gate ───────────────────────────────────────────────────────────
// The SDK-construction + ready() await is built ONCE in `makeReadySDK`; goal data is built ONCE in
// `makeGoalData`; the recovered-event read-back is the shared `conversionData(from:)` helper; the
// "exactly one conversion entry was recorded" assertion is the shared `soleConversion(in:)` helper. No
// case re-inlines SDK construction or the encode/decode round-trip (CPD is token-based — shared helpers,
// not renamed locals, hold the diff under the gate).
import Testing
import Foundation
@testable import ConvertSwiftSDK

// MARK: - ConversionEventData read-back (no production-code change)

/// Recovers the ``ConversionEventData`` carried by a captured ``TrackingEventEntry`` WITHOUT touching
/// the frozen DTO. ``TrackingEventEntry``'s `payload` is `private`, so there is no in-memory accessor
/// for the conversion struct — but the entry IS `Codable` and encodes to the wire shape
/// `{"eventType":"conversion","data":{…flat ConversionEventData fields…}}`, and ``ConversionEventData``
/// is itself `Codable`. So this round-trips through JSON: encode the whole entry, lift the `data`
/// sub-object out of the top-level object, re-serialize JUST that sub-object, and decode it as
/// ``ConversionEventData``. The conversion path's assertions (`goalId`, `bucketingData`, `goalData`
/// entries) then read the recovered struct's public fields directly — chosen over a production-code
/// accessor on the frozen DTO precisely because it needs no change to `TrackingEvent.swift`.
///
/// Returns `nil` (rather than crashing) when the entry is not a conversion entry, or any step of the
/// round-trip fails — so a wrong-shape capture surfaces as a `nil` the test `#expect` reports, not a
/// trap. Guarding on ``TrackingEventEntry/eventType`` first short-circuits a bucketing entry before the
/// decode is attempted (its `data` has no `goalId`, so the decode would fail anyway). File-private —
/// the conversion suite is its sole consumer (kept here, not in `MockPorts.swift`, so that file stays
/// under SwiftLint's 400-line `file_length`).
private func conversionData(from entry: TrackingEventEntry) -> ConversionEventData? {
    guard entry.eventType == "conversion" else { return nil }
    guard let encoded = try? JSONEncoder().encode(entry),
          let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
          let dataObject = object["data"],
          let dataBytes = try? JSONSerialization.data(withJSONObject: dataObject) else {
        return nil
    }
    return try? JSONDecoder().decode(ConversionEventData.self, from: dataBytes)
}

// MARK: - ConvertContext trackConversion wiring (Story 4.2)

@Suite("ConversionTracking")
@MainActor
struct ConversionTrackingTests {
    /// The goal key every ready-path test converts on — declared once so the fixture build and the
    /// `trackConversion(_:)` call never re-spell the literal (SonarQube 3% gate).
    private static let goalKey = "purchase"
    /// The wire goal id the fixture's goal carries; the conversion event's `goalId` must equal it.
    private static let goalId = "goal-77"

    /// The fully-wired conversion system-under-test plus the collaborators a test drives and observes.
    /// A named struct (not a large tuple) keeps the `large_tuple` lint rule satisfied and lets tests
    /// read collaborators by name. `Sendable` — `ConvertSwiftSDK` is `Sendable`, `MockEventSink` is an
    /// `actor`, `DecisionStore` is an `actor`, and `MockLogger` is a `Sendable` final class.
    private struct ConversionSUT: Sendable {
        /// The system under test — built ready (its config carries the goal), with the injected sink /
        /// logger / decision store wired in.
        let sdk: ConvertSwiftSDK
        /// The sink the wired `trackConversion` enqueues the conversion entry into; inspect via
        /// `recordedEvents()`.
        let sink: MockEventSink
        /// The structured-log spy; `entries(...)` filters the WARN lines the drop paths emit.
        let logger: MockLogger
        /// The SAME canonical `DecisionStore` the SDK injects into its contexts — held so a test can
        /// seed a sticky decision (AC6) under the store key the context computes.
        let store: DecisionStore
    }

    /// Builds a READY off-network SDK whose live config carries the goal `(goalKey → goalId)`, with an
    /// injected `MockEventSink` (so the conversion enqueue is observable), `MockLogger` (so the drop-path
    /// WARNs are observable), and an explicit `DecisionStore` (so AC6 can seed a sticky decision under
    /// the key the context computes), then awaits `ready()` so `createContext().trackConversion(goalKey)`
    /// sees a NON-`nil` snapshot. Centralised so no case copy-pastes the provider build + `ready()` await
    /// (SonarQube 3% gate). Mirrors `ConvertContextRunExperienceTests.makeReadySDK`: a `MockConfigProvider`
    /// canned `(cached: nil, live: <goal config>)` keeps the SDK off the network and resolves `ready()`
    /// non-degraded with that snapshot.
    ///
    /// ASSUMES THE GREEN SEAM: the `eventSink:` and `logger:` parameters do not exist on `ConvertSwiftSDK.init`
    /// yet, so this factory does not compile until GREEN adds them — the file-level RED signal.
    private func makeReadySDK(
        goalKey: String = Self.goalKey,
        goalId: String = Self.goalId
    ) async throws -> ConversionSUT {
        let sink = MockEventSink()
        let logger = MockLogger()
        let store = DecisionStore(logger: MockLogger(), fileStore: MockFileStore())
        let sdk = ConvertSwiftSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(
                cached: nil,
                live: try makeGoalConfig(goalKey: goalKey, goalId: goalId)
            ),
            eventSink: sink,
            logger: logger,
            decisionStore: store
        )
        try await sdk.ready()
        return ConversionSUT(sdk: sdk, sink: sink, logger: logger, store: store)
    }

    /// Builds a small ``GoalData`` map. Single owner of the literal so the goal-data tests do not each
    /// re-inline the dictionary (SonarQube 3% gate). Defaults to the AC8 metric pair (`amount` +
    /// `transactionId`); callers needing other shapes override.
    private func makeGoalData(
        amount: Double = 9.99,
        transactionId: String = "txn-001"
    ) -> GoalData {
        [.amount: .double(amount), .transactionId: .string(transactionId)]
    }

    /// The store key the context computes for `visitorId` — `"<accountId>-<projectId>-<visitorId>"` over
    /// the fixture's shared `account_id` / `project.id`. Single owner so the AC6 seed and the context's
    /// computed key cannot drift (they MUST match for the seeded decision to surface in `bucketingData`).
    private func storeKey(visitorId: String) -> String {
        "\(conversionFixtureAccountId)-\(conversionFixtureProjectId)-\(visitorId)"
    }

    /// Recovers the SINGLE conversion entry's ``ConversionEventData`` from the sink, asserting exactly
    /// one entry was recorded along the way. Single owner of the "exactly one conversion enqueued, read
    /// it back" step so the goalId / goalData / bucketingData / pre-ready cases do not each re-inline the
    /// count check + `conversionData(from:)` round-trip (SonarQube 3% gate). Returns `nil` (so the
    /// caller's `#expect` reports it) when the count is not exactly one or the read-back fails.
    private func soleConversion(in sink: MockEventSink) async -> ConversionEventData? {
        let recorded = await sink.recordedEvents()
        guard recorded.count == 1 else { return nil }
        return conversionData(from: recorded[0])
    }

    // MARK: - Drop paths (AC1 unknown goal, AC10 pre-ready)

    /// AC1: `trackConversion` for a goal key ABSENT from the ready config DROPS — nothing is enqueued —
    /// and emits a WARN naming the unresolved goal. The fixture carries only `"purchase"`, so
    /// `"no-such-goal"` misses `ProjectConfig.goal(forKey:)`; the wired path logs WARN + returns without
    /// enqueuing. FAILS today: the no-op stub neither logs nor (trivially) enqueues, so the WARN
    /// assertion fails (and would mask a future spurious enqueue). The WARN is observable ONLY because
    /// the GREEN seam injects the `MockLogger` — if logger injection is dropped, this becomes a
    /// no-enqueue-only assertion (see report).
    @Test("trackConversion on an unknown goal key drops the event and warns")
    func unknownGoalDropsAndWarns() async throws {
        let sut = try await makeReadySDK()
        await sut.sdk.createContext(visitorId: "user-1").trackConversion("no-such-goal")

        #expect(await sut.sink.recordedEvents().isEmpty, "an unknown goal must enqueue nothing")
        let warnings = sut.logger.entries(type: "ConvertContext", method: "trackConversion")
            .filter { $0.level == .warn && $0.message.contains("not found") }
        #expect(!warnings.isEmpty, "an unknown goal must emit a WARN naming the missing goal")
    }

    /// AC10: `trackConversion` on a context whose SDK has NO usable snapshot (pre-ready / degraded)
    /// DROPS — nothing is enqueued — and emits a WARN that the SDK is not ready. Built with
    /// `MockConfigProvider.ungated(cached: nil, live: nil)` and WITHOUT `await ready()` (mirroring
    /// `runExperiencePreReadyReturnsNil`): the snapshot is `nil`, so the wired path short-circuits on the
    /// absent snapshot BEFORE any goal lookup. FAILS today: the no-op stub emits no WARN. Constructs the
    /// SDK inline (NOT via `makeReadySDK`, which awaits `ready()` and supplies a goal config) because the
    /// whole point is a never-ready, config-less SDK — a distinct construction, not a copy-paste of the
    /// ready factory.
    @Test("trackConversion before ready (no snapshot) drops the event and warns")
    func preReadyDropsAndWarns() async throws {
        let sink = MockEventSink()
        let logger = MockLogger()
        let sdk = ConvertSwiftSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(cached: nil, live: nil),
            eventSink: sink,
            logger: logger
        )
        await sdk.createContext(visitorId: "user-1").trackConversion(Self.goalKey)

        #expect(await sink.recordedEvents().isEmpty, "a pre-ready conversion must enqueue nothing")
        let warnings = logger.entries(type: "ConvertContext", method: "trackConversion")
            .filter { $0.level == .warn && $0.message.contains("not ready") }
        #expect(!warnings.isEmpty, "a pre-ready conversion must emit a not-ready WARN")
    }

    // MARK: - bucketingData (AC6 — anti-android regression)

    /// AC6 (MANDATORY anti-android-bucketingdata regression): when the visitor has a sticky decision,
    /// the conversion event's `bucketingData` carries it. Seeds `("exp-1" → "var-a")` into the SDK's
    /// canonical `DecisionStore` UNDER THE KEY THE CONTEXT COMPUTES (`storeKey(visitorId:)`) BEFORE
    /// converting, then asserts the recovered `ConversionEventData.bucketingData == ["exp-1": "var-a"]`.
    /// This is the regression guard: the wired path MUST read the visitor's `DecisionStore.bucketingDecisions`
    /// and attach them — the Android SDK once shipped conversions with an EMPTY bucketingData. FAILS
    /// today: the no-op stub enqueues nothing, so `soleConversion` is `nil` and the equality fails.
    @Test("trackConversion attaches the visitor's sticky decisions as bucketingData")
    func bucketingDataReflectsStickyDecisions() async throws {
        let sut = try await makeReadySDK()
        let visitorId = "user-1"
        await sut.store.saveDecision(
            variationId: "var-a",
            experienceId: "exp-1",
            storeKey: storeKey(visitorId: visitorId)
        )

        await sut.sdk.createContext(visitorId: visitorId).trackConversion(Self.goalKey)

        let data = await soleConversion(in: sut.sink)
        #expect(data?.bucketingData == ["exp-1": "var-a"])
    }

    /// AC6 (negative): a visitor with NO sticky decision yields `bucketingData == nil` — an absent map,
    /// not an empty one (the wire omits the key entirely). No seed; convert; assert the recovered
    /// `bucketingData` is `nil`. FAILS today: the no-op stub enqueues nothing, so `soleConversion` is
    /// `nil` and the precondition `data != nil` fails — the expected RED signal until the real path
    /// enqueues a conversion whose `bucketingData` is `nil`.
    @Test("trackConversion with no sticky decisions leaves bucketingData nil")
    func bucketingDataNilWhenNoDecisions() async throws {
        let sut = try await makeReadySDK()
        await sut.sdk.createContext(visitorId: "user-1").trackConversion(Self.goalKey)

        let data = await soleConversion(in: sut.sink)
        #expect(data != nil, "a ready known-goal conversion must enqueue exactly one entry")
        #expect(data?.bucketingData == nil, "no sticky decisions must leave bucketingData absent")
    }

    // MARK: - goalData (AC11 absent, AC8 present)

    /// AC11: `trackConversion` with NO `goalData` yields `goalData == nil` on the conversion event — the
    /// optional metric array is absent (omitted from the wire). Convert with the default `goalData: nil`;
    /// assert the recovered `goalData` is `nil`. FAILS today: the stub enqueues nothing.
    @Test("trackConversion without goalData leaves goalData nil")
    func goalDataNilWhenOmitted() async throws {
        let sut = try await makeReadySDK()
        await sut.sdk.createContext(visitorId: "user-1").trackConversion(Self.goalKey)

        let data = await soleConversion(in: sut.sink)
        #expect(data != nil, "a ready known-goal conversion must enqueue exactly one entry")
        #expect(data?.goalData == nil, "an omitted goalData must be absent on the event")
    }

    /// AC1/AC8 (Story 4.3 dedup): a FIRST `trackConversion` carrying `goalData` enqueues TWO conversion
    /// entries — `recorded[0]` the CONVERSION event (`goalData == nil`) and `recorded[1]` the TRANSACTION
    /// event carrying the caller's metrics (`goalData == makeGoalData().toEntries()`). Both are
    /// `eventType == "conversion"`. Converts with `[.amount: .double(9.99), .transactionId:
    /// .string("txn-001")]` (via `makeGoalData`), then recovers BOTH events via `conversionData(from:)`
    /// and asserts the split: the conversion event carries no metrics, and the transaction event carries
    /// BOTH structurally — `amount == 9.99` and `transactionId == "txn-001"`. `GoalDataValue` is NOT
    /// `Equatable`, so the metric assertions inspect each entry's `key` + unwrapped `value` via the
    /// structural readers rather than comparing `[GoalDataEntry]`. (Story 4.2 emitted a SINGLE event
    /// carrying the metrics; the 4.3 dedup contract splits it in two.)
    @Test("trackConversion with goalData carries each metric as an entry")
    func goalDataCarriesEntries() async throws {
        let sut = try await makeReadySDK()
        await sut.sdk.createContext(visitorId: "user-1")
            .trackConversion(Self.goalKey, goalData: makeGoalData())

        let recorded = await sut.sink.recordedEvents()
        #expect(recorded.count == 2, "a first conversion with goalData enqueues a conversion + a transaction")
        let first = conversionData(from: recorded[0])
        let second = conversionData(from: recorded[1])
        #expect(first?.goalData == nil, "the conversion event carries no goalData")
        let entries = second?.goalData ?? []
        #expect(entries.count == 2, "both supplied metrics are carried on the transaction event")
        #expect(doubleValue(of: .amount, in: entries) == 9.99)
        #expect(stringValue(of: .transactionId, in: entries) == "txn-001")
    }

    // MARK: - System event + wire tag (AC9 fire, AC7 eventType)

    /// AC9: `trackConversion` fires `SystemEvent.conversion` on the SDK's bus. Subscribes via the SDK's
    /// public `on(.conversion)` BEFORE converting, then — because `EventBus.fire` delivers each callback
    /// as a `MainActor` task — flushes with `await MainActor.run { }` (a serial-executor barrier, NOT
    /// `Task.yield()`) before reading the captured flag. A `LockedBox<Bool>` carries the flag so the
    /// `@Sendable` callback mutates it data-race-free. FAILS today: the no-op stub fires nothing, so the
    /// flag stays `false`.
    @Test("trackConversion fires SystemEvent.conversion on the SDK bus")
    func firesConversionSystemEvent() async throws {
        let sut = try await makeReadySDK()
        let fired = LockedBox<Bool>(false)
        let token = await sut.sdk.on(.conversion) { _ in fired.set(true) }

        await sut.sdk.createContext(visitorId: "user-1").trackConversion(Self.goalKey)
        await MainActor.run { }

        #expect(fired.get, "a tracked conversion must fire SystemEvent.conversion")
        await sut.sdk.off(token)
    }

    /// AC7: the enqueued entry went through the `EventSink` port AS A CONVERSION entry — its
    /// `eventType == "conversion"` (and its recovered `goalId` is the fixture's wire goal id, proving the
    /// goalKey → goalId mapping). FAILS today: the stub enqueues nothing, so the recorded list is empty
    /// and both the count and the `eventType` assertion fail.
    @Test("trackConversion enqueues a conversion-typed entry carrying the wire goalId")
    func enqueuesConversionTypedEntry() async throws {
        let sut = try await makeReadySDK()
        await sut.sdk.createContext(visitorId: "user-1").trackConversion(Self.goalKey)

        let recorded = await sut.sink.recordedEvents()
        #expect(recorded.count == 1, "exactly one conversion entry must be enqueued")
        #expect(recorded.first?.eventType == "conversion")
        #expect(await soleConversion(in: sut.sink)?.goalId == Self.goalId)
    }

    // MARK: - GoalDataValue structural readers (not Equatable)

    /// The `Double` behind the `key`-keyed entry in `entries`, or `nil` when absent / not a `.double`.
    /// `GoalDataValue` is NOT `Equatable`, so the goal-data assertions read the bare value through these
    /// helpers rather than comparing values directly — centralised so each metric assertion does not
    /// re-inline the find-then-switch (SonarQube 3% gate).
    private func doubleValue(of key: GoalDataKey, in entries: [GoalDataEntry]) -> Double? {
        guard case let .double(value)? = entries.first(where: { $0.key == key })?.value else {
            return nil
        }
        return value
    }

    /// The `String` behind the `key`-keyed entry in `entries`, or `nil` when absent / not a `.string`
    /// (the `.double` twin above — see its doc for why structural readers, not `==`).
    private func stringValue(of key: GoalDataKey, in entries: [GoalDataEntry]) -> String? {
        guard case let .string(value)? = entries.first(where: { $0.key == key })?.value else {
            return nil
        }
        return value
    }
}
