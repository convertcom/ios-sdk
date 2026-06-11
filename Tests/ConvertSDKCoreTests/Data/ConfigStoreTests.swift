// Tests/ConvertSDKCoreTests/Data/ConfigStoreTests.swift
// `ConfigStore` is assumed `public actor` so a plain import reaches it; `@testable` is used
// anyway to stay consistent with the rest of this target and to keep the test resilient if
// the impl phase makes `ConfigStore` (or its `setConfig`) internal. The ready signal is
// observed through the public `EventBus` (`on(.ready)` + `setConfig`), never via the
// `internal fire`, so this suite drives only the documented ready-gate contract.
import Testing
@testable import ConvertSDKCore

/// RED-phase contract for the `ConfigStore` ready gate (Epic 2 / Story 2, FR/AR ready-once).
///
/// CONTRACT under test (the GREEN-phase implementer MUST satisfy these):
/// - `waitForReady()` suspends until the first `setConfig`, then resumes (and returns
///   immediately for any later caller once config is present).
/// - The first `setConfig` fires `SystemEvent.ready` exactly once via the owned `EventBus`;
///   a second `setConfig` does NOT re-fire `.ready`.
///
/// `ConfigStore` does not exist yet, so this suite is EXPECTED to fail to compile (RED).
///
/// NOTE TO IMPL PHASE: the exact `setConfig` signature is not yet locked. This suite calls
/// `setConfig()` with NO arguments to avoid coupling the RED test to a guessed parameter. If
/// the finalized signature takes an argument (e.g. a `Bool` present-sentinel or a config
/// payload), reconcile these two call sites during GREEN.
@Suite("ConfigStore ready gate")
struct ConfigStoreTests {
    // MARK: Shared fixtures & helpers (SonarQube 3% new-duplicated-lines gate)

    /// Fresh bus + store per scenario — one factory instead of re-wiring the pair per test.
    private func makeSut() -> (store: ConfigStore, bus: EventBus) {
        let bus = EventBus()
        return (ConfigStore(eventBus: bus), bus)
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

    // MARK: Scenario 1 — waitForReady resumes once config is set

    @Test("waitForReady() resumes after the first setConfig()")
    func waitForReadyResumesAfterSetConfig() async throws {
        let sut = makeSut()
        // Mark config present from a child task; `waitForReady()` must suspend until it lands
        // and then resume rather than hang. Returning from the awaited call IS the assertion.
        Task { await sut.store.setConfig() }
        try await sut.store.waitForReady()
        #expect(Bool(true))
    }

    // MARK: Scenario 2 — .ready fires exactly once across two setConfig calls

    @Test("the first setConfig() fires .ready exactly once; the second does not re-fire")
    func readyFiresExactlyOnceAcrossTwoSetConfig() async {
        let sut = makeSut()
        await confirmation(".ready is delivered exactly once", expectedCount: 1) { fired in
            _ = await sut.bus.on(.ready) { _ in fired() }
            await sut.store.setConfig()
            await sut.store.setConfig()
            await drain()
        }
    }
}
