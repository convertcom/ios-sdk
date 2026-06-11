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

/// Drives the subscribe → fire-via-`ready()` → drain → unsubscribe dance inside a
/// caller-supplied confirmation, so the two suites that assert `.ready` delivery
/// (`ready()` fires exactly once; `on/off` forwards to the bus) do not duplicate the
/// block. `readyCalls` lets a caller fire `ready()` more than once to prove the event still
/// latches to a single delivery. The `confirmation`'s `expectedCount` (owned by the caller)
/// is what actually asserts the delivery count.
@MainActor
private func confirmReadyDelivery(
    sut: ConvertSDK,
    readyCalls: Int,
    fired: @escaping @Sendable () -> Void
) async throws {
    let token = await sut.on(.ready) { _ in fired() }
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
        let sut = makeSut()
        await confirmation("the .ready event is delivered exactly once", expectedCount: 1) { fired in
            try await confirmReadyDelivery(sut: sut, readyCalls: 2, fired: fired)
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
        let sut = makeSut()
        await confirmation("the on(.ready) subscriber receives the fired event", expectedCount: 1) { fired in
            try await confirmReadyDelivery(sut: sut, readyCalls: 1, fired: fired)
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
    @MainActor
    @Test("ready(completion:) invokes the completion on MainActor exactly once")
    func completionCalledOnMainActor() async {
        let sut = makeSut()
        await confirmation("the completion is invoked once", expectedCount: 1) { done in
            sut.ready(completion: { _ in done() })
            await drain()
        }
    }
}
