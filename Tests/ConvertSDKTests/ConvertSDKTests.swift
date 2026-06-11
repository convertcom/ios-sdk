// Tests/ConvertSDKTests/ConvertSDKTests.swift
// `@testable` import: these suites construct `ConvertSDK` through its INTERNAL
// dependency-injecting initializer (a deliberate test seam) so a unit test never
// touches the network. The public `init(configuration:)` delegates to that same seam
// with a production config provider. Reaching the internal init requires `@testable`.
//
// RED phase ([SDK-2] — wiring the real config fetch into `ConvertSDK.init`): the GREEN
// step has NOT yet introduced the ``ConfigProviding`` protocol nor changed the internal
// init to take `configProvider:`. Every reference below to that protocol and to the
// `configProvider:` init parameter is EXPECTED to fail compilation until GREEN builds
// them. That compile-fail is the correct outcome of this phase. (The rest of the SDK
// surface — `ConvertSDK(...)` / `ready()` / `on` / `off` / `createContext` /
// `ConvertContext` — already compiles from Story 2.2.)
//
// Assumed GREEN seam (so the implementer matches these call sites):
//   public protocol ConfigProviding: Sendable {
//       func loadCachedConfig() async -> ProjectConfig?
//       func fetchLiveConfig() async -> ProjectConfig?
//   }
//   internal init(
//       configuration: ConvertConfiguration,
//       configProvider: (any ConfigProviding)? = nil,   // nil → build the real ConfigFetchService
//       eventBus: EventBus = EventBus(),
//       directData: Data? = nil
//   )
// The internal init's config-load Task (AFTER the UNCHANGED empty-key validation branch,
// which still `signalError`s → `ready()` throws) resolves a provider, then:
//   if let cached = await provider.loadCachedConfig() { await store.setConfig(cached) }
//   let live = await provider.fetchLiveConfig()
//   await store.setConfig(live)
// ``ConfigStore/setConfig(_:)`` latches the ready signal on its first non-terminal call,
// so the unconditional final `setConfig(live)` (possibly `nil`) guarantees `ready()`
// resolves — non-degraded if cache OR live produced a config, DEGRADED if both were `nil`.
// The `configLoader:` parameter + production `StubConfigLoader` wiring are REMOVED from the
// init by GREEN; the direct-data path (`validateAndSetConfig`) is UNCHANGED. The previous
// `ConfigLoader` mocks are superseded by ``MockConfigProvider`` (in `MockPorts.swift`).
import Testing
import Foundation
@testable import ConvertSDK

// MARK: - Shared fixtures (SonarQube 3% new-duplicated-lines gate)

/// Default SDK key used by `makeSut`; non-empty so the happy paths pass validation.
private let validSdkKey = "test-key"

/// A valid ``ProjectConfig`` decoded from a tiny wire payload carrying the given `accountId`,
/// for the suites that need a NON-`nil` config whose identity they can assert on (e.g. proving
/// WHICH config — cached vs live — the snapshot holds). Centralized so the decode literal is
/// never copy-pasted per test (SonarQube 3% new-duplicated-lines gate). `ProjectConfig` decodes
/// field-by-field and never throws on this shape, so `try` is satisfied without a fixture file.
private func makeConfig(accountId: String) throws -> ProjectConfig {
    try JSONDecoder().decode(
        ProjectConfig.self,
        from: Data(#"{"account_id":"\#(accountId)","project":{"id":"p-1"}}"#.utf8)
    )
}

/// A valid, minimal ``ProjectConfig`` for the suites that only need a NON-`nil` config so
/// `ready()` resolves non-degraded (its identity is irrelevant). Delegates to ``makeConfig(accountId:)``
/// with a fixed `accountId` so the decode literal lives in exactly one place. The JSON mirrors
/// `ConfigFetchServiceTests.validConfigJSON`.
private func makeValidConfig() throws -> ProjectConfig {
    try makeConfig(accountId: "acc-1")
}

/// Single construction site for the system-under-test, reused across every suite so the
/// `ConvertConfiguration` build + internal-init wiring is never copy-pasted per test.
///
/// `@MainActor` because the entry-point suites drive it from `MainActor`-affined bodies
/// (confirmations whose callbacks land on `MainActor`); the SDK's internal init itself is
/// non-async (the handle is constructed synchronously and the config-load runs in a
/// detached Task), so the factory does not need to `await`. The injected `configProvider`
/// keeps the SUT off the network: callers pass a ``MockConfigProvider`` whose canned
/// `(cached, live)` pair drives the ready outcome. The default is a cache-miss + live-success
/// provider (`cached: nil, live: makeValidConfig()`) so the bare `makeSut()` happy paths
/// resolve `ready()` NON-degraded; suites needing other outcomes pass an explicit provider.
@MainActor
private func makeSut(
    sdkKey: String = validSdkKey,
    configProvider: any ConfigProviding
) -> ConvertSDK {
    let configuration = ConvertConfiguration(sdkKey: sdkKey)
    return ConvertSDK(
        configuration: configuration,
        configProvider: configProvider
    )
}

/// Convenience overload: the default happy-path SUT (cache miss + live success), so the bare
/// `makeSut()` / `makeSut(sdkKey:)` call sites read unchanged and resolve `ready()`
/// non-degraded without each test constructing a provider. `throws` because building the live
/// ``ProjectConfig`` decodes JSON.
@MainActor
private func makeSut(sdkKey: String = validSdkKey) throws -> ConvertSDK {
    makeSut(
        sdkKey: sdkKey,
        configProvider: MockConfigProvider.ungated(cached: nil, live: try makeValidConfig())
    )
}

/// Lets already-dispatched `MainActor` callbacks run before a `confirmation` body exits.
///
/// `EventBus.fire` (and the completion overload) deliver each callback as a
/// `Task { @MainActor in … }`. Awaiting `MainActor.run { }` enqueues a barrier job behind
/// those already-hopped callback jobs; because the `MainActor` executor is serial/FIFO, the
/// barrier completes only after every prior callback has run. `Task.yield()` does NOT
/// suffice — it yields the cooperative pool and never awaits the separate `MainActor`
/// executor. This is a pure executor barrier, not a wall-clock wait (NFR21/22). Mirrors
/// `Tests/ConvertSDKCoreTests/Event/EventBusTests.swift`.
private func drain() async {
    await MainActor.run { }
}

/// Drives the subscribe → release-gated-fetch → `ready()` → drain → unsubscribe dance inside a
/// caller-supplied confirmation, so the two suites that assert `.ready` delivery
/// (`ready()` fires exactly once; `on/off` forwards to the bus) do not duplicate the block.
/// `readyCalls` lets a caller await `ready()` more than once to prove the event still latches
/// to a single delivery. The `confirmation`'s `expectedCount` (owned by the caller) is what
/// actually asserts the delivery count.
///
/// Subscribes via `sut.on(.ready)` (exercising the SDK's bus forwarding) BEFORE releasing the
/// GATED ``MockConfigProvider``, so the init task fires `.ready` strictly after the subscriber
/// is registered — making delivery deterministic regardless of scheduler interleaving. The
/// provider is built with `cached: nil` so the ready signal is driven by the gated live fetch's
/// `setConfig(live)` (not by the cache), and `live: someConfig` so the resolve is non-degraded.
/// The SUT is built here (rather than passed in) so the gate is wired and the
/// subscribe-before-fire ordering is owned in one place.
///
/// Why the gate exists (the deterministic-ordering fix carried over from the previous seam):
/// the SDK races to fire the one-shot, latching `.ready` the instant it is constructed. A
/// subscriber attached AFTER that fire never sees it (the locked ``ConfigStore`` contract), so
/// without gating the subscribe-vs-fire order is non-deterministic under parallel execution
/// (`Confirmation was confirmed 0 times` under suite load). Gating the LIVE FETCH makes the
/// fire happen strictly after the subscription — a pure continuation handoff, no sleep, no
/// wall-clock (NFR21/22) — WITHOUT weakening production: the SDK still fires once and latches;
/// the test merely controls when the fetch (hence the fire) completes, the way the real network
/// would.
@MainActor
private func confirmReadyDelivery(
    readyCalls: Int,
    fired: @escaping @Sendable () -> Void
) async throws {
    let provider = MockConfigProvider.makeGated(cached: nil, live: try makeValidConfig())
    let sut = ConvertSDK(
        configuration: ConvertConfiguration(sdkKey: validSdkKey),
        configProvider: provider
    )
    let token = await sut.on(.ready) { _ in fired() }
    await provider.release()
    for _ in 0..<readyCalls {
        try await sut.ready()
    }
    await drain()
    await sut.off(token)
}

/// Asserts that `ready()` RESOLVES (never throws, never hangs) for a SUT backed by an ungated
/// ``MockConfigProvider`` with the given `(cached, live)` pair — the shared body for the three
/// "ready resolves" outcome tests (degraded-no-network, from-cache, degraded-no-cache).
/// Extracted so those tests do not copy-paste the provider-build + `#expect(throws: Never)` +
/// `await ready()` block (SonarQube 3% new-duplicated-lines gate); each test stays a one-line
/// call documenting its own `(cached, live)` scenario. Reaching the return is the proof the gate
/// latched: `#expect(throws: Never.self)` fails if `ready()` throws, and a hang would never
/// return. Non-`throws` — it forwards already-built configs; a caller that needs a non-`nil`
/// config decodes it at the call site (`try makeValidConfig()`) before passing it in.
@MainActor
private func expectReadyResolves(cached: ProjectConfig?, live: ProjectConfig?) async {
    let sut = makeSut(configProvider: MockConfigProvider.ungated(cached: cached, live: live))
    await #expect(throws: Never.self) {
        try await sut.ready()
    }
}

// MARK: - init

@Suite("ConvertSDK init")
struct ConvertSDKInitTests {
    /// The initializer returns a usable handle on the current task WITHOUT the caller
    /// `await`ing the init itself — config loading happens in a detached Task, so
    /// construction never blocks (FR / non-blocking-init contract). The assertion is
    /// structural: this body constructs the SUT and immediately reaches an instance member
    /// with no `await` on the construction expression. That this compiles and runs is the
    /// proof of a non-async, non-blocking initializer.
    @MainActor
    @Test("init returns a usable handle synchronously, without blocking")
    func initReturnsWithoutBlocking() throws {
        let sut = try makeSut()
        // Reaching a member of the just-constructed handle, with no `await` on the init,
        // demonstrates the initializer returned immediately.
        let context = sut.createContext()
        #expect(context as ConvertContext? != nil)
    }

    /// `ConvertSDK.shared` is `nil` until an explicit opt-in assignment — construction alone
    /// must not install a global singleton.
    @Test("shared is nil by default")
    func sharedIsNilByDefault() {
        #expect(ConvertSDK.shared == nil)
    }
}

// MARK: - ready()

@Suite("ready()")
struct ConvertSDKReadyTests {
    /// With a cache-miss + live-success provider injected, `ready()` resolves (no throw, no
    /// hang) once the live fetch yields a config and the ready gate latches non-degraded.
    @MainActor
    @Test("ready resolves after the mock config load completes")
    func readyResolvesAfterMockConfigLoad() async throws {
        let sut = try makeSut()
        try await sut.ready()
    }

    /// The ready gate latches: a second `ready()` after the first has resolved returns
    /// immediately (the config is already present) rather than suspending again.
    @MainActor
    @Test("a second ready() call returns immediately")
    func secondReadyCallReturnsImmediately() async throws {
        let sut = try makeSut()
        try await sut.ready()
        try await sut.ready()
    }

    /// `.ready` fires EXACTLY once even when `ready()` is awaited twice — the underlying
    /// gate latches, so the event is delivered a single time. `expectedCount: 1` is the
    /// assertion; the shared helper drives the subscribe/fire/drain/off sequence.
    @MainActor
    @Test("ready() fires the .ready event exactly once across repeated calls")
    func readyFiresReadyEventExactlyOnce() async throws {
        try await confirmation("the .ready event is delivered exactly once", expectedCount: 1) { fired in
            try await confirmReadyDelivery(readyCalls: 2, fired: { fired() })
        }
    }

    /// An empty SDK key is rejected: `ready()` surfaces a `ConvertError` (the key is
    /// validated, not silently loaded). Empty-key/invalid-direct-data are the ONLY throwing
    /// paths for `ready()`. This path runs BEFORE the config provider is consulted (the
    /// validation branch `signalError`s and returns), so the injected provider is irrelevant —
    /// the default happy-path provider is used and never reached.
    @MainActor
    @Test("ready() throws on an empty SDK key")
    func readyThrowsOnEmptySdkKey() async throws {
        let sut = try makeSut(sdkKey: "")
        await #expect(throws: ConvertError.self) {
            try await sut.ready()
        }
    }

    /// A transient network failure during config load must NOT propagate from `ready()`:
    /// the SDK resolves degraded. Under the new seam a "transient network failure with no
    /// cache" is modeled by a provider returning `nil` for BOTH cache and live; the
    /// unconditional final `setConfig(nil)` still latches ready degraded, so `ready()` never
    /// throws. (Same intent as the previous `FailingMockConfigLoader`-backed test.)
    @MainActor
    @Test("ready() resolves degraded (never throws) on a transient network failure")
    func readyResolvesDegradedOnNetworkFailure() async {
        await expectReadyResolves(cached: nil, live: nil)
    }

    /// AC3 (task 6.6) — OFFLINE-WITH-CACHE: when the live fetch fails but a cached config is
    /// present, the SDK resolves `ready()` FROM CACHE. With `(cached: aValidConfig, live: nil)`,
    /// the init task's `setConfig(cached)` latches ready BEFORE the (nil) live fetch, so
    /// `ready()` returns without throwing and without hanging — `#expect(throws: Never.self)`
    /// returning IS the proof that the cache satisfied readiness offline.
    @MainActor
    @Test("ready() resolves from cache when the live fetch fails")
    func readyResolvesFromCacheOnNetworkFailure() async throws {
        await expectReadyResolves(cached: try makeValidConfig(), live: nil)
    }

    /// AC3 (FIX-R1-1) — OFFLINE-WITH-CACHE keeps the cached SNAPSHOT, not just the ready latch.
    /// `ready()` resolving from cache (``readyResolvesFromCacheOnNetworkFailure``) only proves the
    /// gate latched; bucketing reads `getSnapshot()`, so the cached config must SURVIVE the failed
    /// live refresh. With `(cached: acc-cache, live: nil)`, after `ready()` the snapshot must still
    /// be the cached config — a `nil` live result must NOT clobber it. Before the guarded-`setConfig`
    /// fix this FAILS: the unconditional `setConfig(nil)` overwrites the snapshot to `nil`.
    @MainActor
    @Test("a failed live refresh after a cache hit preserves the cached snapshot")
    func cacheHitThenLiveFailPreservesSnapshot() async throws {
        let sut = makeSut(
            configProvider: MockConfigProvider.ungated(cached: try makeConfig(accountId: "acc-cache"), live: nil)
        )
        try await sut.ready()
        #expect(await sut.configStore.getSnapshot()?.accountId == "acc-cache")
    }

    /// AC3 (FIX-R1-1) — companion to ``cacheHitThenLiveFailPreservesSnapshot``: a SUCCESSFUL live
    /// fetch after a cache hit REFRESHES the snapshot to the fresh config (fresh wins). With
    /// `(cached: acc-cache, live: acc-live)`, after `ready()` the snapshot is the live config. This
    /// documents the refresh-wins half of the contract and passes both before and after the fix
    /// (a non-`nil` live is always set), guarding against a fix that over-corrects into never
    /// refreshing.
    @MainActor
    @Test("a successful live fetch after a cache hit refreshes the snapshot to the live config")
    func liveSuccessAfterCacheUpdatesSnapshot() async throws {
        let sut = makeSut(
            configProvider: MockConfigProvider.ungated(
                cached: try makeConfig(accountId: "acc-cache"),
                live: try makeConfig(accountId: "acc-live")
            )
        )
        try await sut.ready()
        #expect(await sut.configStore.getSnapshot()?.accountId == "acc-live")
    }
}

// MARK: - on/off forwarding

@Suite("on/off forwarding")
struct ConvertSDKOnOffTests {
    /// A subscription made via `sut.on(.ready)` receives the `.ready` that `sut.ready()`
    /// triggers — proving `on` is wired to the SAME `EventBus` the SDK fires through (AC6:
    /// this test asserts the forwarding is connected; deeper `on`/`off` semantics —
    /// selective removal, idempotent double-off, cross-event isolation — are covered by
    /// `EventBusTests`). `off(token)` then returns without error, confirming the cancel path
    /// is wired too. Reuses the shared delivery helper, so it shares no copy-pasted block
    /// with `readyFiresReadyEventExactlyOnce` (it differs only in intent + `readyCalls`).
    @MainActor
    @Test("on(.ready) receives the event that ready() fires, and off() is wired")
    func onOffForwardsToEventBus() async throws {
        try await confirmation("the on(.ready) subscriber receives the fired event", expectedCount: 1) { fired in
            try await confirmReadyDelivery(readyCalls: 1, fired: { fired() })
        }
    }
}

// MARK: - createContext

@Suite("createContext")
struct ConvertSDKCreateContextTests {
    /// `createContext` returns a non-nil ``ConvertContext`` synchronously even when called
    /// BEFORE `ready()` resolves — context creation does not block on config load.
    @MainActor
    @Test("createContext before ready() returns a non-nil context")
    func createContextBeforeReadyReturnsNonNil() throws {
        let sut = try makeSut()
        let context = sut.createContext(visitorId: "v1")
        #expect(context as ConvertContext? != nil)
    }
}

// MARK: - completion overload

@Suite("completion overload")
struct ConvertSDKCompletionTests {
    /// The `ready(completion:)` overload delivers its result on `MainActor` (the closure is
    /// `@MainActor`). The completion is dispatched via a `Task`, so `drain()` flushes the
    /// `MainActor` executor before the confirmation body exits. `expectedCount: 1` asserts
    /// the completion fires once; the drain is the (wall-clock-free, NFR21/22) flush
    /// mechanism, not a timing assertion.
    ///
    /// The confirmation body AWAITS the completion deterministically via
    /// `withCheckedContinuation` (RED-phase timing-bug fix), instead of firing the overload
    /// and flushing with a single `drain()`. The completion overload spawns a detached `Task`
    /// that `await`s the config-load chain before hopping to `MainActor` to invoke the
    /// completion; a lone `drain()` barrier could return before that `Task` reached its hop,
    /// leaving (a) the `Confirmation` possibly observing 0 confirmations and (b) the orphaned
    /// detached `Task` still live in the concurrency runtime after the body exited — which, in
    /// the combined test process, kept the runtime's main queue non-empty and prevented the
    /// test binary from exiting (a post-"all tests passed" hang; `--skip`ping only this test
    /// let the suite exit cleanly). Bridging the callback to the body's `await` resumes the
    /// body exactly when the completion fires on `MainActor`: `done()` is recorded and the
    /// detached `Task` runs to completion BEFORE the body returns, so nothing lingers and the
    /// process exits. `expectedCount: 1` still asserts a single MainActor delivery. This fixes
    /// a genuine test/runtime race; it does NOT weaken production — the `ready(completion:)`
    /// overload is exercised exactly as shipped (its result still arrives on `MainActor`).
    @MainActor
    @Test("ready(completion:) invokes the completion on MainActor exactly once")
    func completionCalledOnMainActor() async throws {
        let sut = try makeSut()
        await confirmation("the completion is invoked once", expectedCount: 1) { done in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                sut.ready(completion: { _ in
                    done()
                    continuation.resume()
                })
            }
        }
    }
}
