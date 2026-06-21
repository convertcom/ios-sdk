// Tests/ConvertSwiftSDKCoreTests/Data/ConfigStoreTests.swift
// `ConfigStore` is assumed `public actor` so a plain import reaches it; `@testable` is used
// anyway to stay consistent with the rest of this target and to keep the test resilient if
// the impl phase makes `ConfigStore` (or its `setConfig`) internal. The ready signal is
// observed through the public `EventBus` (`on(.ready)` + `setConfig`), never via the
// `internal fire`, so this suite drives only the documented ready-gate contract.
import Foundation
import Testing
@testable import ConvertSwiftSDKCore

/// RED-phase contract for the `ConfigStore` ready gate (Epic 2 / Story 2 + Story 2.3 snapshot).
///
/// CONTRACT under test (the GREEN-phase implementer MUST satisfy these):
/// - `waitForReady()` suspends until the first `setConfig(_:)`, then resumes (and returns
///   immediately for any later caller once the gate is ready).
/// - The first NON-terminal `setConfig(_:)` fires `SystemEvent.ready` exactly once via the
///   owned `EventBus`; a second `setConfig(_:)` (any argument) does NOT re-fire `.ready`.
/// - `setConfig(nil)` while `!isReady` is a valid DEGRADED first load (F-019 / AOD-4): it
///   STILL signals ready (resumes `waitForReady()`) and fires `.ready` once, with a `nil`
///   snapshot — this prevents a forever-hang when both cache and network fail.
/// - `getSnapshot()` returns the value last passed to `setConfig(_:)` (the current snapshot);
///   a later `setConfig(_:)` updates the snapshot even though it does NOT re-fire `.ready`.
/// - `waitForReady()` is cancellation-aware (F-170 / FR44): a cancelled waiter throws
///   `CancellationError` promptly without blocking on the request timeout, and cancelling one
///   waiter does not disturb other concurrent waiters.
///
/// Story 2.3 LOCKED the signature to `setConfig(_ config: ProjectConfig?) async` (replacing
/// the Story 2 no-arg `setConfig()`) and added `getSnapshot() -> ProjectConfig?`. Those
/// members do not exist on the actor yet, so this suite is EXPECTED to fail to compile (RED).
@Suite("ConfigStore ready gate")
struct ConfigStoreTests {
    // MARK: Shared fixtures & helpers (SonarQube 3% new-duplicated-lines gate)

    /// Fresh bus + store per scenario — one factory instead of re-wiring the pair per test.
    private func makeSut() -> (store: ConfigStore, bus: EventBus) {
        let bus = EventBus()
        return (ConfigStore(eventBus: bus), bus)
    }

    /// Builds a `ProjectConfig` by decoding a minimal JSON literal — the single source of the
    /// decode payload so no test re-inlines it (SonarQube CPD operates on tokens, not names).
    /// `ProjectConfig` is `Decodable`-only (no public memberwise init), so decoding a literal is
    /// the sanctioned way to construct instances. `accountId` populates from `account_id`.
    private func makeConfig(accountId: String) throws -> ProjectConfig {
        let json = #"{"account_id":"\#(accountId)","project":{"id":"p-1"}}"#
        return try JSONDecoder().decode(ProjectConfig.self, from: Data(json.utf8))
    }

    /// Lets already-dispatched `MainActor` callbacks run before a confirmation body exits.
    ///
    /// `EventBus.fire` delivers each `.ready` callback as a `Task { @MainActor in … }`, so the
    /// drain must await the `MainActor`'s serial executor — not the cooperative pool. `await
    /// MainActor.run { }` enqueues a barrier job behind the already-hopped callback jobs;
    /// because the `MainActor` executor is serial/FIFO, the barrier completes only after every
    /// prior callback has run. `Task.yield()` does NOT suffice — it yields the cooperative
    /// thread and never awaits the separate `MainActor` executor. Pure executor barrier, no
    /// wall-clock wait (NFR21/NFR22). Mirrors `EventBusTests.drain()`.
    private func drain() async {
        await MainActor.run { }
    }

    /// Drives the ready → refresh transition once: the FIRST `setConfig(first)` flips the gate
    /// ready (fires `.ready`), the SECOND `setConfig(second)` is a post-ready refresh (fires
    /// `.configUpdated` with `second` as its snapshot), then drains so every dispatched
    /// `MainActor` callback has run before the caller asserts. Single owner of the two-call
    /// refresh sequence so neither refresh test re-inlines it (SonarQube CPD is token-based, so
    /// the duplicated block — not the variable names — is what would trip the gate).
    private func fireRefresh(
        on sut: (store: ConfigStore, bus: EventBus),
        first: ProjectConfig?,
        second: ProjectConfig?
    ) async {
        await sut.store.setConfig(first)
        await sut.store.setConfig(second)
        await drain()
    }

    /// Unwraps the `accountId` carried by a `.configUpdated` payload's snapshot; `nil` for any
    /// other case (or a snapshot-less payload). Keeps the `switch` out of the test bodies and
    /// gives the refresh-payload assertion one identifying field to compare — `ProjectConfig`
    /// is `Decodable`/`Sendable` but NOT `Equatable`, so a field compare is the sanctioned check.
    /// Mirrors `EventBusTests.experienceId(of:)`.
    private static func snapshotAccountId(of payload: EventPayloadValue) -> String? {
        guard case let .configUpdated(updated) = payload else { return nil }
        return updated.snapshot?.accountId
    }

    // MARK: Scenario 1 — waitForReady resumes once config is set

    @Test("waitForReady() resumes after the first setConfig(_:)")
    func waitForReadyResumesAfterSetConfig() async throws {
        let sut = makeSut()
        // Mark the gate ready from a child task; `waitForReady()` must suspend until it lands
        // and then resume rather than hang. `setConfig(nil)` is the simplest faithful trigger —
        // a degraded first load still resumes waiters. Returning from the awaited call IS the
        // assertion.
        Task { await sut.store.setConfig(nil) }
        try await sut.store.waitForReady()
        #expect(Bool(true))
    }

    // MARK: Scenario 2 — .ready fires exactly once across two setConfig calls

    @Test("the first setConfig(_:) fires .ready exactly once; the second does not re-fire")
    func readyFiresExactlyOnceAcrossTwoSetConfig() async {
        let sut = makeSut()
        await confirmation(".ready is delivered exactly once", expectedCount: 1) { fired in
            _ = await sut.bus.on(.ready) { _ in fired() }
            await sut.store.setConfig(nil)
            await sut.store.setConfig(nil)
            await drain()
        }
    }

    // MARK: Scenario 3 — a valid first config signals ready, fires .ready once, snapshots itself

    @Test("setConfig(validConfig) signals ready, fires .ready once, and snapshots the config")
    func setConfigValidConfigSignalsReadyAndFiresReadyOnce() async throws {
        let sut = makeSut()
        let config = try makeConfig(accountId: "acc-1")
        await confirmation(".ready is delivered exactly once", expectedCount: 1) { fired in
            _ = await sut.bus.on(.ready) { _ in fired() }
            await sut.store.setConfig(config)
            await drain()
        }
        // Ready resumes (no hang) and the snapshot is the config that was set.
        try await sut.store.waitForReady()
        #expect(await sut.store.getSnapshot()?.accountId == "acc-1")
    }

    // MARK: Scenario 4 — a nil first config is a DEGRADED ready (F-019), not a hang

    @Test("setConfig(nil) while !isReady signals degraded ready, fires .ready once, snapshot nil")
    func setConfigNilWhenNotReadySignalsDegradedReady() async throws {
        let sut = makeSut()
        await confirmation(".ready is delivered exactly once", expectedCount: 1) { fired in
            _ = await sut.bus.on(.ready) { _ in fired() }
            await sut.store.setConfig(nil)
            await drain()
        }
        // Degraded ready still resumes waiters; the snapshot stays nil.
        try await sut.store.waitForReady()
        #expect(await sut.store.getSnapshot() == nil)
    }

    // MARK: Scenario 5 — a second setConfig updates the snapshot but never re-fires .ready

    @Test("a second setConfig(_:) does not re-fire .ready but does update the snapshot")
    func secondSetConfigDoesNotReFireReady() async throws {
        let sut = makeSut()
        let first = try makeConfig(accountId: "acc-1")
        let second = try makeConfig(accountId: "acc-2")
        await confirmation(".ready fires once across both setConfig calls", expectedCount: 1) { fired in
            _ = await sut.bus.on(.ready) { _ in fired() }
            await sut.store.setConfig(first)
            await sut.store.setConfig(second)
            await drain()
        }
        // .ready did not re-fire, yet the snapshot reflects the SECOND config.
        #expect(await sut.store.getSnapshot()?.accountId == "acc-2")
    }

    // MARK: Scenario 6 — getSnapshot returns the value last passed to setConfig

    @Test("getSnapshot() returns the current config (the value last passed to setConfig)")
    func getSnapshotReturnsCurrentConfig() async throws {
        let sut = makeSut()
        let config = try makeConfig(accountId: "acc-1")
        await sut.store.setConfig(config)
        #expect(await sut.store.getSnapshot()?.accountId == "acc-1")
    }

    // MARK: Scenario 7 — a post-ready setConfig fires .configUpdated once, .ready not re-fired

    /// CORE-1 refresh contract (POSITIVE side): the FIRST `setConfig(_:)` signals ready and fires
    /// `.ready` (NOT `.configUpdated`); the SECOND fires `.configUpdated` EXACTLY ONCE and does
    /// NOT re-fire `.ready`. Both invariants are folded into ONE test (two confirmations over the
    /// same two-call sequence) rather than split across two near-identical tests — that keeps the
    /// `.ready`-once invariant adjacent to the new `.configUpdated`-once firing AND avoids a CPD
    /// duplicate of the existing `secondSetConfigDoesNotReFireReady` setup. The two configs carry
    /// DIFFERENT account ids so the refresh is a genuine change, not a no-op re-set.
    @Test("a second setConfig(_:) on a ready store fires .configUpdated exactly once")
    func secondSetConfigFiresConfigUpdated() async throws {
        let sut = makeSut()
        let first = try makeConfig(accountId: "acc-1")
        let second = try makeConfig(accountId: "acc-2")
        await confirmation(".configUpdated is delivered exactly once", expectedCount: 1) { updated in
            await confirmation(".ready is delivered exactly once", expectedCount: 1) { ready in
                _ = await sut.bus.on(.ready) { _ in ready() }
                _ = await sut.bus.on(.configUpdated) { _ in updated() }
                await fireRefresh(on: sut, first: first, second: second)
            }
        }
    }

    // MARK: Scenario 8 — the refresh .configUpdated payload carries the NEW snapshot

    /// CORE-1 refresh contract (PAYLOAD side): the `.configUpdated` fired by the post-ready
    /// `setConfig(_:)` carries the NEW config as its `snapshot`. Asserted INSIDE the `.configUpdated`
    /// callback (which runs on the `MainActor`), so the captured value never crosses an actor
    /// boundary as mutable state — the same in-closure assertion shape `EventBusTests` uses for
    /// payload checks. `ProjectConfig` is not `Equatable`, so the stable `accountId` identifies the
    /// snapshot: it must be the SECOND config's id, proving the refresh payload reflects the update
    /// rather than the first (ready) config.
    @Test("the refresh .configUpdated payload carries the new snapshot")
    func configUpdatedPayloadCarriesSnapshot() async throws {
        let sut = makeSut()
        let first = try makeConfig(accountId: "acc-1")
        let second = try makeConfig(accountId: "acc-2")
        await confirmation(".configUpdated carries the new snapshot", expectedCount: 1) { received in
            _ = await sut.bus.on(.configUpdated) { payload in
                #expect(Self.snapshotAccountId(of: payload) == "acc-2")
                received()
            }
            await fireRefresh(on: sut, first: first, second: second)
        }
    }

    // MARK: Scenario 9 — cancellation propagates promptly out of waitForReady() (F-170, AC13)

    @Test("a cancelled waitForReady() waiter throws CancellationError without blocking on the request timeout")
    func cancelledWaiterThrowsPromptly() async {
        let sut = makeSut()
        // The gate is NEVER set terminal, so the ONLY way this waiter can finish is cancellation.
        // Before F-170 the bare continuation would never resume → this test would hang until the
        // test-runner timeout; completing at all proves PROMPT cancellation, so no wall-clock
        // assert is needed (NFR21).
        let waiter = Task { try await sut.store.waitForReady() }
        await Task.yield()            // best-effort: let the waiter suspend & register first
        waiter.cancel()
        let result = await waiter.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    // MARK: Scenario 10 — cancelling one waiter de-registers only that waiter (F-170, AC13)

    @Test("cancelling one waiter leaves a concurrent waiter to resolve on the gate's terminal transition")
    func cancellingOneWaiterLeavesOthersToResolve() async {
        let sut = makeSut()
        let cancelled = Task { try await sut.store.waitForReady() }
        let survivor = Task { try await sut.store.waitForReady() }
        await Task.yield()            // best-effort: both suspend & register
        cancelled.cancel()
        let cancelledResult = await cancelled.result
        #expect(throws: CancellationError.self) { try cancelledResult.get() }
        // Resolve the gate by ERROR (a stack-stable API; setConfig's signature evolves in 2.3).
        // The survivor must receive the ConvertError — proving the cancelled waiter's individual
        // de-registration did NOT disturb it.
        await sut.store.signalError(.invalidSdkKey("boom"))
        let survivorResult = await survivor.result
        #expect(throws: ConvertError.self) { try survivorResult.get() }
    }
}
