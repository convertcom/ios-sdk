// ConfigRefreshScheduler.swift
// Foreground / interval config-refresh scheduler with Low-Power-Mode pause
// (Epic 2 / Story 2.4). Lives in the `ConvertSwiftSDK` (platform) target — NOT the
// pure-logic `ConvertSwiftSDKCore` — because it observes app-lifecycle notifications
// and so may import UIKit / AppKit (guarded); the ports it composes
// (`ConfigProviding`, `Clock`, `Logger`) and the `ConfigStore` it writes to are
// Foundation-only and live in `ConvertSwiftSDKCore`.

import ConvertSwiftSDKCore
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The platform foreground notification the scheduler refreshes on: UIKit's
/// `willEnterForeground` on iOS/tvOS, AppKit's `willBecomeActive` on macOS.
///
/// File-private constant so the actor reads ONE source of truth for the name. It is
/// deliberately the SAME name the test support's `ForegroundNotification.name` resolves
/// to (and that `triggerForeground` posts), so production and test observe/post the
/// identical notification. On a platform with neither framework this file does not
/// compile a foreground observer — but every target this package ships to has one.
#if canImport(UIKit)
private let foregroundNotificationName = UIApplication.willEnterForegroundNotification
#elseif canImport(AppKit)
private let foregroundNotificationName = NSApplication.willBecomeActiveNotification
#endif

/// Schedules project-config refreshes from three independent triggers and pauses fetching
/// under Low Power Mode (Story 2.4 — foreground config refresh + LPM pause).
///
/// An `actor` (not a lock-guarded class) so all mutable state — the last-successful-fetch
/// timestamp and the three loop task handles — is actor-isolated and race-free with NO
/// `NSLock` / `os_unfair_lock` / `DispatchQueue` (AC10). The actor owns three long-lived
/// `Task`s started by ``start()`` and torn down by ``cancel()``:
///
/// 1. **Interval loop** — sleeps `refreshIntervalMs` via the injected ``Clock``, then runs a
///    TTL-gated refresh attempt; repeats until cancelled. Driving the sleep through the
///    `Clock` port (not `Task.sleep`) is what lets the suite advance a virtual clock
///    deterministically (NFR21) instead of waiting on the wall clock.
/// 2. **Foreground observer** — awaits the platform foreground notification and runs a
///    TTL-gated attempt on each (AC3), so a return-to-foreground refreshes config without
///    waiting for the next interval, yet honors the TTL so a foreground bounce does not spam
///    the network (AC4 battery-friendliness).
/// 3. **Power-state observer** — awaits `.NSProcessInfoPowerStateDidChange` and, on a
///    transition OUT of Low Power Mode, runs an immediate TTL-skipping refresh (AC6) to
///    catch up on the polling that LPM suppressed.
///
/// ── TTL time source (AC12 — injectable time) ───────────────────────────────────────────
/// The lazy TTL reads ``Clock/now`` (NOT `Date()`), and ``lastSuccessfulFetchAt`` is stamped
/// from ``Clock/now`` on every successful fetch. Reading the injected clock is what makes the
/// TTL gate deterministic under test (the suite moves time via the mock clock); a `Date()`
/// call would couple the gate to the wall clock and break NFR21.
///
/// ── Failure posture (AC7 — serve-last-good) ────────────────────────────────────────────
/// A refresh whose ``ConfigProviding/fetchLiveConfig()`` returns `nil` (network/decode
/// failure) logs ONE `.warn` and leaves the ``ConfigStore`` untouched — the last good
/// snapshot keeps serving indefinitely and NO event is fired. Only a non-nil fetch writes the
/// store (which, post-ready, fires `.configUpdated`).
///
/// ── Teardown via `cancel()`, not `deinit` (AC10) ───────────────────────────────────────
/// Teardown is an explicit ``cancel()`` rather than a `deinit`: an actor `deinit` cannot
/// touch actor-isolated state without hopping, and the owning `Task`s capture `self`, so a
/// `deinit` would never run while the loops are live (the captured `self` keeps the actor
/// alive). Each loop `Task` therefore captures `[weak self]` so a dropped scheduler does not
/// keep itself alive through its own tasks; the OWNER calls ``cancel()`` to stop the loops,
/// which clears the task handles and lets the actor deallocate.
public actor ConfigRefreshScheduler {
    /// The store a successful refresh writes the fresh config to (firing `.configUpdated`
    /// post-ready). A failed refresh never touches it.
    private let configStore: ConfigStore
    /// The config-fetch seam. Typed as `any ConfigProviding` (NOT a concrete service) so the
    /// scheduler composes the same injected provider `ConvertSwiftSDK` uses and a test injects a
    /// counting double. The scheduler only calls ``ConfigProviding/fetchLiveConfig()``.
    private let fetchService: any ConfigProviding
    /// Structured logging sink for the `.debug` skip lines, the `.info` LPM-exit line, and the
    /// `.warn` failed-refresh line.
    private let logger: any Logger
    /// Injectable time source. ``Clock/now`` drives the TTL gate and stamps
    /// ``lastSuccessfulFetchAt``; ``Clock/sleep(milliseconds:)`` parks the interval loop.
    private let clock: any Clock
    /// Reads the current Low-Power-Mode state. `@Sendable` so it crosses into the loop tasks
    /// without a data-race warning; production defaults to `ProcessInfo.isLowPowerModeEnabled`,
    /// a test injects a flippable cell.
    private let powerModeProvider: @Sendable () -> Bool
    /// The center the foreground / power-state observers watch. Injected (defaulting to
    /// `.default`) so each test wires an isolated `NotificationCenter()` and notifications
    /// never leak between parallel tests.
    private let notificationCenter: NotificationCenter
    /// Milliseconds between interval-loop refresh attempts; also the TTL window the lazy gate
    /// compares elapsed time against.
    private let refreshIntervalMs: Int
    /// The instant (per ``Clock/now``) of the last SUCCESSFUL fetch, or `nil` until the first
    /// one lands. The TTL gate skips a refresh while `now - this < refreshIntervalMs`.
    private var lastSuccessfulFetchAt: Date?
    /// The interval-loop task handle, retained so ``cancel()`` can stop it.
    private var intervalTask: Task<Void, Never>?
    /// The opaque token for the foreground observer, retained so ``cancel()`` can remove it.
    private var foregroundObserver: (any NSObjectProtocol)?
    /// The opaque token for the power-state observer, retained so ``cancel()`` can remove it.
    private var powerStateObserver: (any NSObjectProtocol)?

    /// Creates a scheduler wired to the config store, fetch seam, clock, logger, and the
    /// power-mode / notification sources.
    ///
    /// - Parameters:
    ///   - configStore: The store a successful refresh writes to.
    ///   - fetchService: The config-fetch seam (`fetchLiveConfig()` is the only call made).
    ///   - logger: Structured logging sink.
    ///   - clock: Injectable time source for the TTL gate and the interval sleep (AC12).
    ///   - powerModeProvider: Reads the current Low-Power-Mode state; defaults to
    ///     `ProcessInfo.processInfo.isLowPowerModeEnabled`.
    ///   - notificationCenter: The center the observers watch; defaults to `.default`.
    ///   - refreshIntervalMs: Interval between attempts AND the TTL window; defaults to
    ///     ``Defaults/dataRefreshIntervalMs``.
    public init(
        configStore: ConfigStore,
        fetchService: any ConfigProviding,
        logger: any Logger,
        clock: any Clock,
        powerModeProvider: @Sendable @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        notificationCenter: NotificationCenter = .default,
        refreshIntervalMs: Int = Defaults.dataRefreshIntervalMs
    ) {
        self.configStore = configStore
        self.fetchService = fetchService
        self.logger = logger
        self.clock = clock
        self.powerModeProvider = powerModeProvider
        self.notificationCenter = notificationCenter
        self.refreshIntervalMs = refreshIntervalMs
    }

    // MARK: - Lifecycle

    /// Starts the three refresh triggers: the interval loop, the foreground observer, and the
    /// power-state observer.
    ///
    /// The interval loop runs in its own `Task` captured `[weak self]` so the scheduler can
    /// deallocate once its owner drops it and calls ``cancel()`` — the task does not keep `self`
    /// alive. Its body is a thin `await self?.runIntervalLoop()` hop into an actor method, where
    /// `self` is the actor and the loop reads `clock` / `refreshIntervalMs` / the attempt helpers
    /// directly without re-hopping.
    ///
    /// ── Why `addObserver` (synchronous), NOT `notifications(named:)` (async) ─────────────────
    /// The two app-lifecycle observers are registered via the block-based
    /// `addObserver(forName:object:queue:using:)`, which installs the observer SYNCHRONOUSLY before
    /// ``start()`` returns. The async-sequence form (`for await _ in
    /// notificationCenter.notifications(named:)`) registers its underlying observer only once the
    /// observing `Task` reaches its first iteration — but `NotificationCenter` does NOT buffer, so a
    /// notification posted in the window between ``start()`` returning and that first iteration is
    /// DROPPED. A caller that posts a foreground / power-state notification immediately after
    /// ``start()`` (the supported usage, and exactly what the suite drives) would lose it. Eager
    /// synchronous registration closes that race. `queue: nil` lets the observer block run on the
    /// posting thread; it then hops the work onto the actor.
    public func start() {
        intervalTask = Task { [weak self] in
            await self?.runIntervalLoop()
        }
        // The observer block runs the attempt DIRECTLY in a fresh `Task` (no intermediate stream /
        // consumer loop). NotificationCenter invokes the block exactly once per post, so one
        // notification maps to exactly one attempt — no double-delivery. A direct `Task` is the
        // SHORTEST path from delivery to the attempt (fewer scheduling hops than buffering through
        // an `AsyncStream` consumed by a separate parked task), which is what keeps the attempt's
        // side effects observable promptly to a caller draining on them. The `@Sendable` block
        // ignores the (non-Sendable) `Notification` and captures `[weak self]`, so nothing
        // non-Sendable crosses into the actor and the scheduler is not kept alive by its observers.
        foregroundObserver = notificationCenter.addObserver(
            forName: foregroundNotificationName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                // ON-DEMAND refresh: `bypassLPM: true` so a foreground transition fires even under
                // Low Power Mode (AC5 — LPM pauses only PERIODIC polling, not on-demand refresh).
                // `skipTTL: false` keeps the lazy TTL active, so a foreground bounce inside the TTL
                // window is still skipped (AC4 still applies under LPM).
                await self?.attemptRefreshIfDue(skipTTL: false, bypassLPM: true)
            }
        }
        // `.NSProcessInfoPowerStateDidChange` is the Foundation-level, cross-platform name
        // (`API_AVAILABLE(macos(12.0), ios(9.0), …)`) — NOT the non-existent
        // `ProcessInfo.powerStateDidChangeNotification`. It is the same name the LPM-exit path posts.
        powerStateObserver = notificationCenter.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handlePowerStateChange()
            }
        }
    }

    /// Stops every trigger: cancels the interval task and removes the two notification observers.
    ///
    /// Cancelling the interval task trips `Task.isCancelled` and resumes its parked
    /// ``Clock/sleep(milliseconds:)`` — `SystemClock` swallows the cancellation and the loop's
    /// POST-sleep `Task.isCancelled` guard exits WITHOUT a trailing attempt (AC10). Removing each
    /// observer via ``NotificationCenter/removeObserver(_:)`` detaches it so no further foreground /
    /// power-state block fires. A refresh `Task` already in flight from a just-delivered notification
    /// is not force-cancelled (it is a short, self-contained attempt that completes harmlessly);
    /// removal guarantees no NEW attempt starts. Clearing the handle and the observer tokens drops
    /// the actor's last strong references so it can deallocate.
    public func cancel() {
        intervalTask?.cancel()
        intervalTask = nil
        if let foregroundObserver {
            notificationCenter.removeObserver(foregroundObserver)
        }
        if let powerStateObserver {
            notificationCenter.removeObserver(powerStateObserver)
        }
        foregroundObserver = nil
        powerStateObserver = nil
    }

    // MARK: - Loops

    /// The interval loop: sleep one interval, then run a TTL-gated refresh attempt; repeat
    /// until cancelled.
    ///
    /// The POST-sleep `Task.isCancelled` guard is load-bearing (AC10): the injected ``Clock``'s
    /// `sleep` RESUMES on cancellation (mirroring `SystemClock`'s `Task.sleep`), so without this
    /// guard a cancelled loop would run one extra ``attemptRefreshIfDue()`` after teardown.
    /// Checking cancellation immediately after the sleep returns makes ``cancel()`` a clean stop.
    private func runIntervalLoop() async {
        while !Task.isCancelled {
            await clock.sleep(milliseconds: refreshIntervalMs)
            if Task.isCancelled { break }
            await attemptRefreshIfDue()
        }
    }

    // MARK: - Refresh

    /// Runs a refresh attempt subject to the Low-Power-Mode gate and the lazy TTL.
    ///
    /// Order: (1) unless `bypassLPM`, if Low Power Mode is on, skip with a `.debug` line —
    /// PERIODIC (interval) fetching is paused under LPM (AC5), but the interval loop keeps running
    /// so it can still detect LPM exit. (2) Unless `skipTTL`, if a previous fetch landed within
    /// `refreshIntervalMs` ago (per ``Clock/now``), skip with a `.debug` line (AC4); the comparison
    /// is strict `<`, so the boundary value (`elapsed == interval`) PROCEEDS. (3) Otherwise perform
    /// the refresh.
    ///
    /// ── LPM gate vs the two trigger classes (AC5) ───────────────────────────────────────────
    /// The LPM gate suppresses only PERIODIC attempts — the interval loop calls this with BOTH
    /// defaults (`bypassLPM: false`), so interval polling stays paused under LPM. ON-DEMAND
    /// attempts (the foreground observer) pass `bypassLPM: true` so they FIRE even under LPM:
    /// AC5 says refresh-on-foreground (AC3) "still applies even under LPM — LPM does not prevent
    /// on-demand refresh, only periodic polling". Bypassing the LPM gate does NOT touch the TTL
    /// gate, so a foreground attempt under LPM still honors the lazy TTL (AC4 — `skipTTL: false`):
    /// a foreground bounce inside the TTL window is still skipped, LPM or not.
    ///
    /// - Parameters:
    ///   - skipTTL: When `true`, bypass the TTL gate (the LPM-exit path passes this so the
    ///     catch-up refresh is not suppressed by a recent stamp). Orthogonal to `bypassLPM`.
    ///   - bypassLPM: When `true`, bypass the Low-Power-Mode gate so an ON-DEMAND (foreground)
    ///     attempt fires even while LPM is active (AC5). The interval loop leaves this `false`,
    ///     so PERIODIC polling stays paused under LPM. Does NOT affect the TTL gate.
    private func attemptRefreshIfDue(skipTTL: Bool = false, bypassLPM: Bool = false) async {
        guard bypassLPM || !powerModeProvider() else {
            logger.log(
                level: .debug,
                type: "ConfigRefreshScheduler",
                method: "checkRefresh",
                message: "skipping — Low Power Mode active"
            )
            return
        }
        if !skipTTL, let last = lastSuccessfulFetchAt {
            let elapsedMs = clock.now.timeIntervalSince(last) * 1000
            if elapsedMs < Double(refreshIntervalMs) {
                logger.log(
                    level: .debug,
                    type: "ConfigRefreshScheduler",
                    method: "checkRefresh",
                    message: "skipping — last fetch \(Int(elapsedMs)) ms ago"
                )
                return
            }
        }
        await performRefresh()
    }

    /// Fetches the live config and, on success, writes it to the store and stamps the TTL clock.
    ///
    /// A non-nil fetch is written to the ``ConfigStore`` (firing `.configUpdated` post-ready) and
    /// ``lastSuccessfulFetchAt`` is stamped from ``Clock/now`` — the SAME source the TTL gate
    /// reads (AC12). A `nil` fetch (network/decode failure) logs ONE `.warn`, leaves the store
    /// untouched so the last good snapshot keeps serving (AC7), stamps NOTHING, and fires no
    /// event. The WARN detail is routed through ``toLoggable(_:)`` so any secret material in a
    /// cause string is redacted (NFR6), matching the line shape of `ConfigFetchService.warn`.
    private func performRefresh() async {
        let fresh = await fetchService.fetchLiveConfig()
        guard let fresh else {
            logger.log(
                level: .warn,
                type: "ConfigRefreshScheduler",
                method: "refresh",
                message: "config refresh failed — \(toLoggable("network or decode error"))"
            )
            return
        }
        await configStore.setConfig(fresh)
        lastSuccessfulFetchAt = clock.now
    }

    /// Handles a power-state-change notification: on an LPM EXIT, log `.info` and run an
    /// immediate TTL-skipping refresh (AC6).
    ///
    /// Re-reads ``powerModeProvider`` (the notification fires for BOTH directions): if LPM is
    /// still on, there is nothing to do — fetching stays paused. If LPM has just turned off, the
    /// scheduler catches up on the polling LPM suppressed with a `skipTTL: true` attempt (a
    /// recent pre-LPM stamp must not suppress the catch-up).
    private func handlePowerStateChange() async {
        guard !powerModeProvider() else { return }
        logger.log(
            level: .info,
            type: "ConfigRefreshScheduler",
            method: "powerState",
            message: "Low Power Mode exited — resuming polling"
        )
        // This is an ON-DEMAND (LPM-exit) catch-up, not periodic polling. LPM is already confirmed
        // OFF by the guard above, so the LPM gate would pass regardless; `bypassLPM: true` is passed
        // for clarity/consistency with the foreground on-demand path (both bypass the LPM gate). The
        // catch-up still passes `skipTTL: true` so a recent pre-LPM stamp does not suppress it.
        await attemptRefreshIfDue(skipTTL: true, bypassLPM: true)
    }
}
