// SchedulerBox.swift
// A tiny `Sendable` actor that holds the lazily-started `ConfigRefreshScheduler`
// (Epic 2 / Story 2.4 — PLAT-2 wiring phase). Lives in the `ConvertSwiftSDK` (platform)
// target alongside `ConfigRefreshScheduler`, NOT in the pure-logic `ConvertSwiftSDKCore`.

import Foundation

/// Holds the lazily-started refresh scheduler behind an actor so ``ConvertSwiftSDK`` can own it through
/// an immutable `let` (preserving the all-`let` `Sendable` proof) while the detached config-load
/// `Task` SETS it asynchronously after the first config lands.
///
/// ── Why a box (the `Sendable`-proof problem this solves) ─────────────────────────────────────
/// ``ConvertSwiftSDK`` is a `Sendable final class` whose data-race safety the compiler proves from ALL
/// its stored properties being immutable `let`s of `Sendable` types — with NO `@unchecked Sendable`
/// and NO `nonisolated(unsafe)`. The scheduler, however, cannot be constructed at `init` time: it
/// must start only AFTER the first config has latched `ready()`, which happens asynchronously inside
/// the detached load `Task`. A stored `var scheduler` would break the all-`let` proof. This actor is
/// itself `Sendable` (every actor is), so ``ConvertSwiftSDK`` stores it as a `let`; the actor's OWN
/// isolation guards the one mutable `scheduler` reference, moving the mutability off the class and
/// behind a boundary the compiler already reasons about.
///
/// ── Teardown ─────────────────────────────────────────────────────────────────────────────────
/// ``ConvertSwiftSDK/deinit`` cannot `await`, so it hands off to a detached `Task` that calls
/// ``cancelAndClear()`` through this (`Sendable`) box — stopping the scheduler's long-lived loops
/// when the handle is released.
actor SchedulerBox {
    /// The started scheduler, or `nil` until the load `Task` sets it (and after a teardown clear).
    private var scheduler: ConfigRefreshScheduler?

    /// Stores the started scheduler. Called once by the load `Task` after the first config lands.
    func set(_ scheduler: ConfigRefreshScheduler) {
        self.scheduler = scheduler
    }

    /// Cancels the held scheduler (stopping its interval / foreground / power-state loops) and drops
    /// the reference. Safe to call when no scheduler was ever set (the directData path never sets one
    /// and an early-released handle may deinit before the load `Task` sets one) — the optional-chain
    /// is then a no-op.
    func cancelAndClear() async {
        await scheduler?.cancel()
        scheduler = nil
    }
}
