// Tests/ConvertSDKCoreTests/Event/EventBusTests.swift
// `@testable` import: `fire` is `internal` by design (SDK-internal dispatch, not public
// API). Mirrors the established convention in this target for reaching internal symbols
// (see PolymorphicSentinelsTests / ConfigDecodeTests). Tests still cannot mint tokens —
// `EventListenerToken.init` is internal too, but tokens are only ever obtained via `on`.
import Testing
@testable import ConvertSDKCore

/// AC10 behavioral contract for `EventBus` (FR52 / AR12).
///
/// CONTRACT under test (the GREEN-phase implementer MUST satisfy these):
/// - `on(_:callback:)` registers a callback and returns a distinct `EventListenerToken`.
/// - `fire(_:payload:)` invokes every callback registered for that exact event, passing
///   the fired payload, and invokes NO callback registered for a different event.
/// - `off(_:)` removes exactly the one subscription named by the token, idempotently.
///
/// Delivery is asynchronous (callbacks run as independent `MainActor` tasks), so every
/// positive-delivery assertion uses `confirmation` and yields the cooperative thread so
/// the dispatched task can drain — never a wall-clock sleep (NFR21). With `fire` stubbed
/// no-op, the positive-delivery scenarios are EXPECTED to fail (RED); the non-delivery and
/// no-crash scenarios pass trivially.
@Suite("EventBus")
struct EventBusTests {
    // MARK: Shared fixtures & helpers (SonarQube 3% new-duplicated-lines gate)

    /// Fresh bus per scenario — one factory instead of `EventBus()` re-spelled per test.
    private func makeSut() -> EventBus { EventBus() }

    /// Canonical bucketing payload; `id` defaults so most cases need no arguments.
    static func bucketingPayload(_ id: String = "e1") -> EventPayloadValue {
        .bucketing(BucketingPayload(experienceId: id, variationId: "v1", visitorId: "vis1"))
    }

    /// Canonical empty `.ready` payload shortcut.
    static let readyPayload: EventPayloadValue = .ready(ReadyPayload())

    /// Single place that unwraps a `.bucketing` payload's `experienceId`; `nil` for any
    /// other case. Keeps the switch out of individual test bodies.
    static func experienceId(of payload: EventPayloadValue) -> String? {
        guard case let .bucketing(bucketing) = payload else { return nil }
        return bucketing.experienceId
    }

    /// Lets already-dispatched `MainActor` callbacks run before a confirmation body exits.
    /// `Task.yield()` is a pure cooperative suspension point — no timing threshold (NFR21).
    private func drain() async {
        await Task.yield()
    }

    // MARK: Scenario 1 — on + fire delivers the callback with the correct payload

    @Test("on then fire invokes the callback with the fired payload")
    func fireDeliversToSubscriber() async {
        let bus = makeSut()
        await confirmation("subscriber receives the bucketing payload", expectedCount: 1) { received in
            _ = await bus.on(.bucketing) { payload in
                #expect(Self.experienceId(of: payload) == "e1")
                received()
            }
            await bus.fire(.bucketing, payload: Self.bucketingPayload())
            await drain()
        }
    }

    // MARK: Scenario 2 — off by token suppresses delivery

    @Test("fire after off does not invoke the removed callback")
    func offSuppressesDelivery() async {
        let bus = makeSut()
        await confirmation("removed callback is never invoked", expectedCount: 0) { received in
            let token = await bus.on(.bucketing) { _ in received() }
            await bus.off(token)
            await bus.fire(.bucketing, payload: Self.bucketingPayload())
            await drain()
        }
    }

    // MARK: Scenario 3 — every subscriber on an event is invoked

    @Test("fire invokes all subscribers registered for the event")
    func fireDeliversToAllSubscribers() async {
        let bus = makeSut()
        await confirmation("both subscribers are invoked once", expectedCount: 2) { received in
            _ = await bus.on(.bucketing) { _ in received() }
            _ = await bus.on(.bucketing) { _ in received() }
            await bus.fire(.bucketing, payload: Self.bucketingPayload())
            await drain()
        }
    }

    // MARK: Scenario 4 — firing event B does not reach an event-A subscriber

    @Test("fire of one event does not invoke a different event's subscriber")
    func fireDoesNotCrossEvents() async {
        let bus = makeSut()
        await confirmation("the conversion subscriber is never invoked", expectedCount: 0) { received in
            _ = await bus.on(.conversion) { _ in received() }
            await bus.fire(.bucketing, payload: Self.bucketingPayload())
            await drain()
        }
    }

    // MARK: Scenario 5 — fire with no subscribers is a no-op

    @Test("fire with no subscribers does not crash")
    func fireWithNoSubscribersIsNoOp() async {
        let bus = makeSut()
        await bus.fire(.ready, payload: Self.readyPayload)
        await drain()
        // Reaching here without trapping is the assertion.
        #expect(Bool(true))
    }

    // MARK: Scenario 6 — distinct tokens; off(one) leaves the other deliverable

    @Test("on returns distinct tokens and off removes only the named subscription")
    func tokensAreDistinctAndOffIsSelective() async {
        let bus = makeSut()
        await confirmation("only the surviving subscriber is invoked", expectedCount: 1) { received in
            let removed = await bus.on(.bucketing) { _ in
                Issue.record("the removed subscriber must not be invoked")
            }
            let surviving = await bus.on(.bucketing) { _ in received() }
            #expect(removed != surviving)
            await bus.off(removed)
            await bus.fire(.bucketing, payload: Self.bucketingPayload())
            await drain()
        }
    }

    // MARK: Scenario 7 — double-off (and off of an unknown token) is idempotent

    @Test("off is idempotent and ignores tokens from another bus")
    func offIsIdempotent() async {
        let bus = makeSut()
        // A token minted by a different bus was never registered here; `off` must ignore it.
        let foreignToken = await makeSut().on(.bucketing) { _ in }
        await confirmation("surviving subscriber still fires after redundant offs", expectedCount: 1) { received in
            let removable = await bus.on(.bucketing) { _ in
                Issue.record("the removed subscriber must not be invoked")
            }
            _ = await bus.on(.bucketing) { _ in received() }
            await bus.off(removable)
            await bus.off(removable)            // double-off of a known-then-removed token
            await bus.off(foreignToken)         // off of a token never registered on this bus
            await bus.fire(.bucketing, payload: Self.bucketingPayload())
            await drain()
        }
    }
}
