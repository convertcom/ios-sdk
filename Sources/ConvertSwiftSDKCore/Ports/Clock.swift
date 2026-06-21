// Clock.swift
// Port: injectable time source.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

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
    ///
    /// The millisecond value is clamped to a safe ceiling before being scaled to nanoseconds, so
    /// `milliseconds * 1_000_000` can never overflow `UInt64`. The ceiling (≈292 years) sits well
    /// below the overflow point (`UInt64.max / 1_000_000` ≈ 1.8e13 ms, ~584 years) and far above
    /// any real refresh interval (production uses 300_000), so normal values are unaffected.
    public func sleep(milliseconds: Int) async {
        // Clamp to a ceiling that cannot overflow UInt64 when scaled to nanoseconds (×1_000_000).
        // 9_223_372_036_854 ≈ 292 years: within Int range and 9_223_372_036_854 × 1_000_000
        // ≈ 9.2e18 < UInt64.max (≈1.84e19). Normal values (e.g. 300_000) pass through unchanged.
        let safeMs = UInt64(min(max(0, milliseconds), 9_223_372_036_854))
        try? await Task.sleep(nanoseconds: safeMs * 1_000_000)
    }
}
