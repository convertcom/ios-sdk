// Tests/ConvertSwiftSDKTests/GoalDeduplicationTests.swift
// `@testable import ConvertSwiftSDK` (the established cross-target pattern — see `ConversionTrackingTests.swift`):
// this suite reaches the SDK's INTERNAL surface so the separate test target can see `internal` members. It
// lives in its OWN file (not appended to `ConversionTrackingTests.swift`) so neither file trips SwiftLint's
// `file_length` (400) limit.
//
// ── Story 4.3 (Epic 4) — goal deduplication + multiple transactions ────────────────────────────────────
// CHARACTERIZES the SHIPPED behaviour of `ConvertContext.trackConversion(_:goalData:forceMultipleTransactions:)`
// (already implemented — see `ConvertContext.swift`). These tests PASS against the implementation; a FAILURE
// surfaces a real regression, NOT a RED-phase expectation. The contract under test:
//   * A goal's FIRST trigger enqueues the CONVERSION event (`goalData == nil`) and fires `.conversion` once;
//     when `goalData` is present it ALSO enqueues a TRANSACTION event (`goalData == data.toEntries()`).
//   * A REPEAT trigger is deduped: it emits a WARN ("already tracked"), enqueues NO conversion, and does NOT
//     re-fire `.conversion`. It still emits the TRANSACTION event IFF `goalData` is present AND
//     `forceMultipleTransactions == true` (a deliberate repeat purchase).
//   * `forceMultipleTransactions` with NO `goalData` is a no-op (nothing to transact).
//   * The dedup mark is persisted via `DecisionStore.markGoalTriggeredIfNeeded`, so it survives an SDK
//     relaunch over the SAME on-disk store (a second SDK hydrates the mark in `ready()` → `loadFromDisk()`).
//
// ── SonarQube 3% new-duplicated-lines gate ─────────────────────────────────────────────────────────────
// SDK construction + `ready()` is built ONCE in `makeReadySDK`; the goalData literal is built ONCE in
// `purchaseData`; the cross-launch two-SDK build is factored into `makeSdk` so neither launch re-inlines the
// `ConvertSwiftSDK(...)` call. The recovered-event read-back is the shared file-private `conversionData(from:)`
// helper (re-declared minimally — it is file-private in `ConversionTrackingTests.swift`, so not visible
// across files; re-declaring in this distinct file scope is the established pattern and is NOT a CPD problem,
// CPD reasoning per-file). No `@Test` re-inlines SDK construction or the encode/decode round-trip.
import Testing
import Foundation
@testable import ConvertSwiftSDK

// MARK: - ConversionEventData read-back (re-declared, file-private; see header)

/// Recovers the ``ConversionEventData`` carried by a captured ``TrackingEventEntry`` by round-tripping
/// through JSON: encode the whole entry, lift the `data` sub-object out of the top-level object, re-serialize
/// JUST that sub-object, and decode it as ``ConversionEventData`` (the entry's `payload` is `private`, so
/// there is no in-memory accessor). Returns `nil` when the entry is not a conversion entry or any round-trip
/// step fails — so a wrong-shape capture surfaces as a `nil` the test `#expect` reports, not a trap. The twin
/// of the file-private helper in `ConversionTrackingTests.swift` (file-private there, so invisible here).
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

/// The `Double` behind the `key`-keyed entry in `entries`, or `nil` when absent / not a `.double`.
/// ``GoalDataValue`` is NOT `Equatable`, so the metric assertions read the bare value through this structural
/// reader rather than comparing `[GoalDataEntry]`. The twin of the file-private reader in
/// `ConversionTrackingTests.swift` (file-private there, so invisible here).
private func doubleValue(of key: GoalDataKey, in entries: [GoalDataEntry]) -> Double? {
    guard case let .double(value)? = entries.first(where: { $0.key == key })?.value else {
        return nil
    }
    return value
}

// MARK: - GoalDeduplication suite

@Suite("GoalDeduplication")
@MainActor
struct GoalDeduplicationTests {
    /// The goal key every test converts on — declared once so the fixture build and the `trackConversion(_:)`
    /// call never re-spell the literal (SonarQube 3% gate).
    private static let goalKey = "purchase"
    /// The wire goal id the fixture's goal carries.
    private static let goalId = "goal-77"
    /// The visitor every test converts as — the SAME id across a test's calls so the dedup gate keys match.
    private static let visitorId = "user-1"

    /// The fully-wired conversion system-under-test plus the collaborators a test drives and observes. A named
    /// struct (not a large tuple) keeps the `large_tuple` lint rule satisfied. `Sendable` — `ConvertSwiftSDK` is
    /// `Sendable`, `MockEventSink`/`DecisionStore` are actors, `MockLogger` is a `Sendable` final class.
    private struct ConversionSUT: Sendable {
        let sdk: ConvertSwiftSDK
        let sink: MockEventSink
        let logger: MockLogger
        let store: DecisionStore
    }

    /// Builds a READY off-network SDK whose live config carries the goal `(goalKey → goalId)`, with an
    /// injected `MockEventSink` (so the enqueues are observable), `MockLogger` (so the dedup WARN is
    /// observable), and an explicit `DecisionStore` (so the cross-launch test can share its file store), then
    /// awaits `ready()`. Centralised so no case copy-pastes the provider build + `ready()` await (SonarQube 3%
    /// gate). Mirrors `ConversionTrackingTests.makeReadySDK`.
    private func makeReadySDK() async throws -> ConversionSUT {
        let sink = MockEventSink()
        let logger = MockLogger()
        let store = DecisionStore(logger: MockLogger(), fileStore: MockFileStore())
        let sdk = ConvertSwiftSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(
                cached: nil,
                live: try makeGoalConfig(goalKey: Self.goalKey, goalId: Self.goalId)
            ),
            eventSink: sink,
            logger: logger,
            decisionStore: store
        )
        try await sdk.ready()
        return ConversionSUT(sdk: sdk, sink: sink, logger: logger, store: store)
    }

    /// Builds a small ``GoalData`` map carrying just `amount` — single owner of the `[.amount: .double(...)]`
    /// literal so the goal-data tests do not each re-inline the dictionary (SonarQube 3% gate; CPD is
    /// token-based, so the shared builder — not renamed locals — holds the diff under it).
    private func purchaseData(amount: Double = 9.99) -> GoalData {
        [.amount: .double(amount)]
    }

    /// The "already tracked" WARN lines `trackConversion` emits when a repeat trigger is deduped. Single owner
    /// of the filter so the dedup cases do not each re-inline the `entries(...).filter { ... }` chain.
    private func dedupWarnings(in logger: MockLogger) -> [MockLogger.LogEntry] {
        logger.entries(type: "ConvertContext", method: "trackConversion")
            .filter { $0.level == .warn && $0.message.contains("already tracked") }
    }

    // MARK: - AC3 — dedup suppresses the conversion

    /// AC3: a SECOND `trackConversion` on the same goal (same visitor) enqueues ZERO additional events. The
    /// first call enqueues the sole conversion (count 1); the repeat is deduped to a WARN-only no-op, so the
    /// recorded count stays 1.
    @Test("second trackConversion on the same goal enqueues 0 additional events")
    func repeatConversionEnqueuesNothingMore() async throws {
        let sut = try await makeReadySDK()
        let context = sut.sdk.createContext(visitorId: Self.visitorId)
        await context.trackConversion(Self.goalKey)
        #expect(await sut.sink.recordedEvents().count == 1, "the first conversion enqueues exactly one event")

        await context.trackConversion(Self.goalKey)
        #expect(await sut.sink.recordedEvents().count == 1, "the deduped repeat enqueues nothing more")
    }

    /// AC3: the dedup suppression emits a WARN naming the goal as already tracked. Two calls on the same goal
    /// + visitor; the repeat trigger must log the "already tracked" WARN.
    @Test("dedup suppression emits a WARN that the goal was already tracked")
    func dedupEmitsWarning() async throws {
        let sut = try await makeReadySDK()
        let context = sut.sdk.createContext(visitorId: Self.visitorId)
        await context.trackConversion(Self.goalKey)
        await context.trackConversion(Self.goalKey)

        #expect(!dedupWarnings(in: sut.logger).isEmpty, "a deduped repeat must WARN that the goal was tracked")
    }

    // MARK: - AC4 — first conversion with goalData splits into conversion + transaction

    /// AC4: a FIRST `trackConversion` carrying `goalData` enqueues TWO events — `recorded[0]` the CONVERSION
    /// event (`goalData == nil`) and `recorded[1]` the TRANSACTION event carrying the caller's metric
    /// (`amount == 9.99`). Both are `eventType == "conversion"`; ``GoalDataValue`` is not `Equatable`, so the
    /// metric is read via the structural `doubleValue` reader.
    @Test("first trackConversion with goalData enqueues conversion + transaction (2 events)")
    func firstConversionWithDataSplitsInTwo() async throws {
        let sut = try await makeReadySDK()
        await sut.sdk.createContext(visitorId: Self.visitorId)
            .trackConversion(Self.goalKey, goalData: purchaseData())

        let recorded = await sut.sink.recordedEvents()
        #expect(recorded.count == 2, "a first conversion with goalData enqueues a conversion + a transaction")
        #expect(conversionData(from: recorded[0])?.goalData == nil, "the conversion event carries no goalData")
        let txnEntries = conversionData(from: recorded[1])?.goalData ?? []
        #expect(doubleValue(of: .amount, in: txnEntries) == 9.99, "the transaction event carries the metric")
    }

    // MARK: - AC5 — forceMultipleTransactions overrides dedup for the transaction only

    /// AC5: `forceMultipleTransactions` after a goalData-bearing first conversion enqueues ONLY the
    /// transaction. The first call enqueues conversion + transaction (count 2). The forced second call (a new
    /// `amount`) is deduped on the conversion (WARN, no conversion event) but its transaction IS emitted, so
    /// the count rises to 3 — the LAST event carries the new metric (`amount == 19.99`). The count == 3
    /// (not 4) proves no extra conversion slipped in, and the WARN proves the conversion was suppressed.
    @Test("forceMultipleTransactions after dedup enqueues the transaction only")
    func forceAfterDataConversionAddsTransactionOnly() async throws {
        let sut = try await makeReadySDK()
        let context = sut.sdk.createContext(visitorId: Self.visitorId)
        await context.trackConversion(Self.goalKey, goalData: purchaseData())
        #expect(await sut.sink.recordedEvents().count == 2, "the first conversion + transaction enqueues two")

        await context.trackConversion(Self.goalKey, goalData: purchaseData(amount: 19.99),
                                      forceMultipleTransactions: true)

        let recorded = await sut.sink.recordedEvents()
        #expect(recorded.count == 3, "the forced repeat adds the transaction only — no second conversion")
        let lastEntries = conversionData(from: recorded[2])?.goalData ?? []
        #expect(doubleValue(of: .amount, in: lastEntries) == 19.99, "the forced transaction carries 19.99")
        #expect(!dedupWarnings(in: sut.logger).isEmpty, "the forced repeat's conversion is still deduped (WARN)")
    }

    // MARK: - AC6 — force after a no-data first conversion enqueues the transaction only

    /// AC6: a forced `trackConversion` carrying `goalData` AFTER a no-data first conversion enqueues ONLY the
    /// transaction. The first call (no goalData) enqueues just the conversion (count 1). The forced second call
    /// supplies a metric: the conversion is deduped, but its transaction IS emitted, so the count rises to 2.
    @Test("force with goalData after a no-data first conversion enqueues the transaction only")
    func forceAfterNoDataConversionAddsTransactionOnly() async throws {
        let sut = try await makeReadySDK()
        let context = sut.sdk.createContext(visitorId: Self.visitorId)
        await context.trackConversion(Self.goalKey)
        #expect(await sut.sink.recordedEvents().count == 1, "the no-data first conversion enqueues one event")

        await context.trackConversion(Self.goalKey, goalData: purchaseData(), forceMultipleTransactions: true)
        #expect(await sut.sink.recordedEvents().count == 2, "the forced metric adds the transaction only")
    }

    // MARK: - AC5/7.8 — force with no goalData is a no-op

    /// AC5/7.8: `forceMultipleTransactions` with NO `goalData` after dedup adds nothing — there is no metric to
    /// transact. The first call enqueues the conversion (count 1); the forced no-data repeat is deduped and the
    /// transaction gate has no `goalData`, so the count stays 1.
    @Test("force with no goalData after dedup is a no-op (0 additional events)")
    func forceWithoutDataIsNoOp() async throws {
        let sut = try await makeReadySDK()
        let context = sut.sdk.createContext(visitorId: Self.visitorId)
        await context.trackConversion(Self.goalKey)
        #expect(await sut.sink.recordedEvents().count == 1, "the first conversion enqueues one event")

        await context.trackConversion(Self.goalKey, forceMultipleTransactions: true)
        #expect(await sut.sink.recordedEvents().count == 1, "force with nil goalData adds nothing")
    }

    // MARK: - AC13 — the CONVERSION system event fires exactly once

    /// AC13: `SystemEvent.conversion` fires ONCE for a goal and NOT on the deduped repeat. Subscribes a
    /// counter, converts twice on the same goal, drains the `MainActor` callback queue (``EventBus/fire``
    /// delivers on `MainActor`), and asserts a single firing. A `LockedBox<Int>` carries the count so the
    /// `@Sendable` callback mutates it data-race-free.
    @Test("CONVERSION system event fires once, not on the deduped repeat")
    func systemEventFiresOnceAcrossRepeat() async throws {
        let sut = try await makeReadySDK()
        let fireCount = LockedBox<Int>(0)
        let token = await sut.sdk.on(.conversion) { _ in fireCount.withLock { $0 += 1 } }

        let context = sut.sdk.createContext(visitorId: Self.visitorId)
        await context.trackConversion(Self.goalKey)
        await context.trackConversion(Self.goalKey)
        await MainActor.run { }

        #expect(fireCount.get == 1, "the conversion fires once; the deduped repeat must not re-fire")
        await sut.sdk.off(token)
    }

    /// AC13: `SystemEvent.conversion` fires ONCE even when the first call enqueues TWO events (conversion +
    /// transaction). The two enqueues are independent of the single bus signal — only the conversion fires the
    /// event, the transaction does not.
    @Test("CONVERSION system event fires once even when the first call enqueues 2 events")
    func systemEventFiresOnceWithTransaction() async throws {
        let sut = try await makeReadySDK()
        let fireCount = LockedBox<Int>(0)
        let token = await sut.sdk.on(.conversion) { _ in fireCount.withLock { $0 += 1 } }

        await sut.sdk.createContext(visitorId: Self.visitorId)
            .trackConversion(Self.goalKey, goalData: purchaseData())
        await MainActor.run { }

        #expect(fireCount.get == 1, "two events are enqueued but only ONE .conversion fires")
        await sut.sdk.off(token)
    }

    // MARK: - AC8 — dedup persists across an SDK relaunch (shared store file)

    /// Builds a READY off-network SDK over the SUPPLIED `DecisionStore` (so two launches can share one
    /// `MockFileStore`), returning the SDK and its fresh sink. Single owner of the `ConvertSwiftSDK(...)` + `ready()`
    /// build so neither launch in the cross-launch test re-inlines it (SonarQube 3% gate).
    private func makeSdk(store: DecisionStore) async throws -> (sdk: ConvertSwiftSDK, sink: MockEventSink) {
        let sink = MockEventSink()
        let sdk = ConvertSwiftSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(
                cached: nil,
                live: try makeGoalConfig(goalKey: Self.goalKey, goalId: Self.goalId)
            ),
            eventSink: sink,
            logger: MockLogger(),
            decisionStore: store
        )
        try await sdk.ready()
        return (sdk, sink)
    }

    /// AC8: the dedup mark PERSISTS across an SDK relaunch sharing the on-disk decision store. `markGoalTriggered`
    /// encodes the whole store (incl. `goalTriggered`) to the `MockFileStore`; a second SDK built over a FRESH
    /// `DecisionStore` on the SAME file store hydrates that mark in `ready()` → `loadFromDisk()`. SDK#1's
    /// conversion enqueues one event; SDK#2's same-goal/same-visitor conversion is deduped against the
    /// hydrated mark, so SDK#2's sink is EMPTY. The one structurally-distinct test (two SDKs) — acceptable per
    /// the SonarQube exemption; both launches go through `makeSdk` so only the two-SDK orchestration is unique.
    @Test("dedup persists across an SDK relaunch over the shared decision-store file")
    func dedupPersistsAcrossRelaunch() async throws {
        let fileStore = MockFileStore()

        let storeOne = DecisionStore(logger: MockLogger(), fileStore: fileStore)
        let launchOne = try await makeSdk(store: storeOne)
        await launchOne.sdk.createContext(visitorId: Self.visitorId).trackConversion(Self.goalKey)
        #expect(await launchOne.sink.recordedEvents().count == 1, "the first launch tracks the conversion")

        let storeTwo = DecisionStore(logger: MockLogger(), fileStore: fileStore)
        let launchTwo = try await makeSdk(store: storeTwo)
        await launchTwo.sdk.createContext(visitorId: Self.visitorId).trackConversion(Self.goalKey)
        #expect(await launchTwo.sink.recordedEvents().isEmpty, "the relaunch dedups against the persisted mark")
    }
}
