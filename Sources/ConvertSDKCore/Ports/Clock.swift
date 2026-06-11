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
}
