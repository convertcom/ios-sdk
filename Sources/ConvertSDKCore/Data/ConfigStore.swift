// ConfigStore.swift
// Minimal config-presence/ready-gate actor (Epic 2 / Story 2; expanded in Story 2.3).
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Owns the "config is present" state and the one-shot ready gate.
///
/// Config-type-agnostic by design (Decision D4): there is no `ProjectConfig` type yet, so
/// ``setConfig()`` takes no payload — it only flips the ready flag, fires `.ready` once, and
/// resumes any ``waitForReady()`` waiters. Story 2.3 replaces the no-arg ``setConfig()`` with
/// a typed `ProjectConfig` parameter.
///
/// All mutable state (`isReady`, `terminalError`, `continuations`) is actor-isolated, so the
/// ready gate is race-free with no locks (AR12).
///
/// The gate is a one-shot, latched state machine with three states: *pending* → *ready*
/// (success via ``setConfig()``) or *errored* (unrecoverable via ``signalError(_:)``). BOTH
/// terminal states latch: once reached, ``waitForReady()`` resolves the SAME way for every
/// later caller, and the first terminal transition wins (a subsequent `setConfig`/`signalError`
/// is a no-op). Latching the error state — not just the success state — is what makes a
/// ``waitForReady()`` that registers AFTER ``signalError(_:)`` still throw rather than suspend
/// forever (otherwise its continuation would never be resumed → a permanent hang).
public actor ConfigStore {
    /// The owned bus on which `.ready` is fired exactly once.
    private let eventBus: EventBus
    /// Whether the first config has landed (success terminal state). Once `true`, stays `true`.
    private var isReady = false
    /// The unrecoverable error the gate failed with (error terminal state), or `nil` while the
    /// gate has not failed. Once set, stays set — so a ``waitForReady()`` arriving after
    /// ``signalError(_:)`` throws immediately instead of suspending on a continuation that
    /// nothing would ever resume.
    private var terminalError: ConvertError?
    /// Waiters suspended in ``waitForReady()`` before config arrived.
    private var continuations: [CheckedContinuation<Void, Error>] = []

    /// Creates a store that fires `.ready` on the supplied bus.
    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    /// Marks the first config as present: fires `SystemEvent.ready` exactly once via the owned
    /// ``EventBus`` and resumes every ``waitForReady()`` waiter. Subsequent calls are no-ops
    /// (the gate latches), so `.ready` never re-fires. `async` because firing on the bus actor
    /// is an `await`ed cross-actor call. Story 2.3 replaces the no-arg form with a typed
    /// `ProjectConfig` parameter.
    public func setConfig() async {
        guard !isReady, terminalError == nil else { return }
        isReady = true
        await eventBus.fire(.ready, payload: .ready(ReadyPayload()))
        for continuation in continuations {
            continuation.resume()
        }
        continuations.removeAll()
    }

    /// Suspends until the gate reaches a terminal state: returns on ``setConfig()``
    /// (success/degraded), or throws the ``ConvertError`` on ``signalError(_:)``
    /// (unrecoverable). Returns or throws IMMEDIATELY if the gate is already terminal when
    /// called — the success latch (`isReady`) and the error latch (`terminalError`) are both
    /// checked before suspending, so a caller that arrives after the terminal transition is
    /// resolved synchronously rather than registering a continuation that nothing would resume.
    public func waitForReady() async throws {
        if isReady { return }
        if let terminalError { throw terminalError }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuations.append(continuation)
        }
    }

    /// Fails the ready gate with an unrecoverable configuration error: latches the error and
    /// resumes every pending ``waitForReady()`` waiter by *throwing* `error`, so `ready()`
    /// surfaces the ``ConvertError``. The error state LATCHES (stored in `terminalError`), so a
    /// ``waitForReady()`` that registers after this call also throws — without the latch its
    /// continuation would never be resumed and `ready()` would hang forever. A no-op once the
    /// gate is already terminal (ready or errored): the first terminal transition wins. `.ready`
    /// is NOT fired on this path.
    public func signalError(_ error: ConvertError) {
        guard !isReady, terminalError == nil else { return }
        terminalError = error
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
        continuations.removeAll()
    }

    /// Validates `config`'s SDK key and returns the ``ConvertError`` if it is invalid, or `nil`
    /// if it is valid. A pure validation bridge — it does NOT touch the gate — so the SDK's
    /// config-load task can validate, then (on `nil`) run the loader, then ``setConfig()``,
    /// keeping the loader call between validation and readiness.
    ///
    /// Lives on the store because the ``ConfigValidation`` it calls is `internal` to this
    /// module: the cross-module SDK target cannot invoke it, but the store — same module —
    /// can.
    public func validationError(for config: ConvertConfiguration) -> ConvertError? {
        do {
            try ConfigValidation.validate(config)
            return nil
        } catch {
            return error
        }
    }

    /// Validates pre-fetched config `data`, then resolves the gate: on non-empty data, marks
    /// config present via ``setConfig()``; on empty/invalid data, fails the gate via
    /// ``signalError(_:)`` so `ready()` throws. The direct-data path has no loader step, so
    /// validation and readiness are a single store operation here (Story 2.3 adds the real
    /// structural decode in the validator).
    public func validateAndSetConfig(data: Data) async {
        do {
            try ConfigValidation.validate(data)
        } catch {
            // `signalError` is intentionally synchronous (non-`async`): it must run to
            // completion on this actor without yielding between catching the validation
            // error and latching/resuming on it, so no interleaved `setConfig`/`signalError`
            // can race the terminal transition.
            signalError(error)
            return
        }
        await setConfig()
    }
}
