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
    /// Waiters suspended in ``waitForReady()`` before config arrived, keyed by a per-call
    /// `UUID` so a cancelled waiter can be de-registered individually (F-170) without disturbing
    /// the others. Resumed en masse by ``setConfig()``/``signalError(_:)``, or one-at-a-time by
    /// ``cancelWaiter(_:)`` on task cancellation.
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

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
        for continuation in continuations.values {
            continuation.resume()
        }
        continuations.removeAll()
    }

    /// Suspends until the gate reaches a terminal state: returns on ``setConfig()``
    /// (success/degraded), throws the ``ConvertError`` on ``signalError(_:)`` (unrecoverable),
    /// or throws `CancellationError` if the awaiting task is cancelled before either terminal
    /// transition. Returns or throws IMMEDIATELY if the gate is already terminal — or the task
    /// already cancelled — when called: the success latch (`isReady`), the error latch
    /// (`terminalError`), and `Task.isCancelled` are all checked before suspending, so a caller
    /// that arrives after a terminal/cancelled transition is resolved synchronously rather than
    /// registering a continuation that nothing would resume.
    ///
    /// Cancellation-aware (F-170, FR44). The suspend is wrapped in
    /// ``withTaskCancellationHandler(operation:onCancel:)`` and the continuation is keyed by a
    /// fresh `UUID` in ``continuations``. If the awaiting task is cancelled while suspended,
    /// ``cancelWaiter(_:)`` de-registers that ONE waiter and resumes it throwing
    /// `CancellationError` — so a caller that wraps its own timeout around `ready()` unblocks
    /// PROMPTLY instead of stalling until the URLSession request timeout (~30 s). The terminal
    /// and `Task.isCancelled` re-checks INSIDE the continuation body close the
    /// cancel-before-register and resolve-before-register races (the body runs actor-isolated).
    public func waitForReady() async throws {
        if isReady { return }
        if let terminalError { throw terminalError }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Re-check the latches and cancellation here, inside the actor-isolated body:
                // between the early-out guards above and this point the gate may have gone
                // terminal, or the task may have been cancelled before the handler installed.
                // Resolving here instead of registering closes both races.
                if isReady {
                    continuation.resume()
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[id] = continuation
                }
            }
        } onCancel: {
            // Runs OUTSIDE actor isolation, synchronously on the cancelling task. Hop back onto
            // the actor to de-register and resume the specific waiter; a no-op if a terminal
            // transition already resumed it (``cancelWaiter(_:)`` guards with `removeValue`).
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Resumes the single ``waitForReady()`` waiter registered under `id` by throwing
    /// `CancellationError`, after de-registering it. A no-op if that waiter was already resumed
    /// by ``setConfig()``/``signalError(_:)`` (`removeValue` returns `nil`), so a continuation is
    /// never resumed twice. Actor-isolated; invoked from the `onCancel` handler's hop-on `Task`.
    private func cancelWaiter(_ id: UUID) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
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
        for continuation in continuations.values {
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
