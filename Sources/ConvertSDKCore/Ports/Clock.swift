// Clock.swift
// Port: injectable time source.
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Injectable time source for the SDK.
///
/// Production code reads the current instant through this port instead of calling
/// `Date()` directly, so unit tests can substitute a deterministic clock and never depend
/// on the wall clock (NFR21).
public protocol Clock: Sendable {
    /// The current instant, as reported by the injected time source.
    var now: Date { get }

    /// Suspends the current task for at least `milliseconds`, using the injected time source.
    /// Production sleeps via `Task.sleep`; tests advance a virtual clock without wall-clock waiting (NFR21).
    func sleep(milliseconds: Int) async
}

/// The production `Clock`: reads the system wall clock and sleeps via structured concurrency.
public struct SystemClock: Clock {
    /// Creates a system clock.
    public init() {}

    /// The current system instant.
    public var now: Date { Date() }

    /// Suspends for at least `milliseconds` via `Task.sleep`. A cancellation during the sleep is
    /// swallowed (`try?`) — the SDK's refresh loops treat a cancelled sleep as "stop quietly", and
    /// the loop's own `Task.isCancelled` check governs termination.
    public func sleep(milliseconds: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }
}
