// Tests/ConvertSDKTests/ConvertSDKTests.swift
// `@testable` import: these suites construct `ConvertSDK` through its INTERNAL
// dependency-injecting initializer (a deliberate test seam) so a unit test never
// touches the network. The public `init(configuration:)` delegates to that same seam
// with a production loader. Reaching the internal init requires `@testable`.
//
// RED phase (Epic 2 / Story 2): the production entry point does not exist yet —
// `Sources/ConvertSDK/ConvertSDK.swift` is currently only `@_exported import
// ConvertSDKCore`. Every reference below to `ConvertSDK(...)` / `ready()` / `on` / `off`
// / `createContext` / `ConvertContext`, and to the `ConfigLoader` port the mocks
// conform to, is EXPECTED to fail compilation until the GREEN step builds them. That
// compile-fail is the correct outcome of this phase.
//
// Assumed GREEN seam (so the implementer matches these call sites):
//   internal init(
//       configuration: ConvertConfiguration,
//       configLoader: ConfigLoader,
//       eventBus: EventBus = EventBus()
//   )
//   public protocol ConfigLoader: Sendable { func load(sdkKey: String) async throws }
// The internal init launches the async config-load Task that calls
// `try await configLoader.load(sdkKey:)` then `configStore.setConfig()` on success, and
// on a thrown network error still resolves `ready()` degraded (does NOT rethrow).
import Testing
import Foundation
@testable import ConvertSDK

// MARK: - Shared fixtures (SonarQube 3% new-duplicated-lines gate)

/// Default SDK key used by `makeSut`; non-empty so the happy paths pass validation.
private let validSdkKey = "test-key"

/// Single construction site for the system-under-test, reused across every suite so the
/// `ConvertConfiguration` build + internal-init wiring is never copy-pasted per test.
///
/// `@MainActor` because the entry-point suites drive it from `MainActor`-affined bodies
/// (confirmations whose callbacks land on `MainActor`); the SDK's internal init itself is
/// non-async (the handle is constructed synchronously and the config-load runs in a
/// detached Task), so the factory does not need to `await`. Pass `configLoader: nil` to get
/// the always-succeeding ``MockConfigLoader``; pass ``FailingMockConfigLoader`` to exercise
/// the degraded path.
@MainActor
private func makeSut(
    sdkKey: String = validSdkKey,
    configLoader: (any ConfigLoader)? = nil
) -> ConvertSDK {
    let configuration = ConvertConfiguration(sdkKey: sdkKey)
    return ConvertSDK(
        configuration: configuration,
        configLoader: configLoader ?? MockConfigLoader()
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

/// A ``ConfigLoader`` whose `load` parks until ``release()`` is called, so a test can
/// register a `.ready` subscriber via `sut.on(.ready)` BEFORE the SDK's init task fires
/// `.ready` (which only happens after `load` returns and `setConfig` runs).
///
/// Why this exists (RED-phase timing-bug fix): the SDK begins loading config — and therefore
/// races to fire the one-shot, latching `.ready` — the instant it is constructed in `init`.
/// `.ready` fires exactly once and latches (the locked ``ConfigStore`` contract), so a
/// subscriber attached AFTER that fire never sees it. The original ``confirmReadyDelivery``
/// subscribed via `sut.on(.ready)` only after `makeSut()` had already constructed (and thus
/// possibly already fired on) the SUT, an order that is non-deterministic under parallel test
/// execution: it passed in isolation but `Confirmation was confirmed 0 times` under suite
/// load. Gating `load` makes the fire happen strictly after the subscription, deterministically
/// (a pure continuation handoff — no sleep, no wall-clock; NFR21/22), WITHOUT weakening
/// production: the SDK still fires once and latches; the test simply controls when the load
/// (hence the fire) completes, the way the real network would.
private actor GateConfigLoader: ConfigLoader {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    /// Parks until ``release()``; returns immediately if already released.
    func load(sdkKey: String) async throws {
        if released { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
        }
    }

    /// Unblocks a parked (or future) ``load``, letting the init task proceed to fire `.ready`.
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Drives the subscribe → release-gated-load → `ready()` → drain → unsubscribe dance inside a
/// caller-supplied confirmation, so the two suites that assert `.ready` delivery
/// (`ready()` fires exactly once; `on/off` forwards to the bus) do not duplicate the block.
/// `readyCalls` lets a caller await `ready()` more than once to prove the event still latches
/// to a single delivery. The `confirmation`'s `expectedCount` (owned by the caller) is what
/// actually asserts the delivery count.
///
/// Subscribes via `sut.on(.ready)` (exercising the SDK's bus forwarding) BEFORE releasing the
/// ``GateConfigLoader``, so the init task fires `.ready` strictly after the subscriber is
/// registered — making delivery deterministic regardless of scheduler interleaving. The SUT
/// is built here (rather than passed in) so the gate loader is wired and the
/// subscribe-before-fire ordering is owned in one place.
@MainActor
private func confirmReadyDelivery(
    readyCalls: Int,
    fired: @escaping @Sendable () -> Void
) async throws {
    let loader = GateConfigLoader()
    let sut = ConvertSDK(
        configuration: ConvertConfiguration(sdkKey: validSdkKey),
        configLoader: loader
    )
    let token = await sut.on(.ready) { _ in fired() }
    await loader.release()
    for _ in 0..<readyCalls {
        try await sut.ready()
    }
    await drain()
    await sut.off(token)
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
    func initReturnsWithoutBlocking() {
        let sut = makeSut()
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
    /// With a succeeding loader injected, `ready()` resolves (no throw, no hang) once the
    /// mock config load completes and the ready gate latches.
    @MainActor
    @Test("ready resolves after the mock config load completes")
    func readyResolvesAfterMockConfigLoad() async throws {
        let sut = makeSut()
        try await sut.ready()
    }

    /// The ready gate latches: a second `ready()` after the first has resolved returns
    /// immediately (the config is already present) rather than suspending again.
    @MainActor
    @Test("a second ready() call returns immediately")
    func secondReadyCallReturnsImmediately() async throws {
        let sut = makeSut()
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
    /// paths for `ready()`.
    @MainActor
    @Test("ready() throws on an empty SDK key")
    func readyThrowsOnEmptySdkKey() async {
        let sut = makeSut(sdkKey: "")
        await #expect(throws: ConvertError.self) {
            try await sut.ready()
        }
    }

    /// A transient network failure during config load must NOT propagate from `ready()`:
    /// the SDK resolves degraded. With the failing loader injected, `ready()` never throws.
    @MainActor
    @Test("ready() resolves degraded (never throws) on a transient network failure")
    func readyResolvesDegradedOnNetworkFailure() async {
        let sut = makeSut(configLoader: FailingMockConfigLoader())
        await #expect(throws: Never.self) {
            try await sut.ready()
        }
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
    func createContextBeforeReadyReturnsNonNil() {
        let sut = makeSut()
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
    func completionCalledOnMainActor() async {
        let sut = makeSut()
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
