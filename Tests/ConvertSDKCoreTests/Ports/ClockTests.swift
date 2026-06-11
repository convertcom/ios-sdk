// Tests/ConvertSDKCoreTests/Ports/ClockTests.swift
// `@testable` import keeps this consistent with the rest of the target; `SystemClock` is the
// public production `Clock` adapter, so a plain import would also reach it. Both members under
// test (`SystemClock` and `Clock.sleep(milliseconds:)`) do not exist yet, so this suite is
// EXPECTED to fail to compile until the GREEN phase lands them (RED).
import Foundation
import Testing
@testable import ConvertSDKCore

/// RED-phase contract for the production `SystemClock` adapter (CORE-1).
///
/// CONTRACT under test (the GREEN-phase implementer MUST satisfy these):
/// - `SystemClock().now` delegates to the system wall clock (`Date()`) — its value falls between
///   two `Date()` samples taken immediately around the read, i.e. it is a current instant, not a
///   fixed or stale one. This is an identity/ordering check on sequenced samples, NOT an elapsed-
///   duration assertion — there is no timing threshold (NFR21).
/// - `SystemClock().sleep(milliseconds:)` is an `async` no-op-on-zero that simply RESUMES — a zero
///   delay completes and control returns. Reaching the line after `await` IS the assertion; the
///   elapsed time is never measured (NFR21).
@Suite("SystemClock")
struct ClockTests {
    /// Fresh adapter per scenario — one factory instead of `SystemClock()` re-spelled per test.
    private func makeSut() -> SystemClock { SystemClock() }

    // MARK: Scenario 1 — now delegates to the system clock

    @Test("now returns a current instant (between two surrounding Date() samples)")
    func systemClockNowReturnsCurrentInstant() {
        let before = Date()
        let now = makeSut().now
        let after = Date()
        // Ordering of instants sampled in sequence — `before <= now <= after` — proves `now`
        // reads the live system clock rather than a fixed value. Not a duration/timeout assert.
        #expect(before <= now)
        #expect(now <= after)
    }

    // MARK: Scenario 2 — sleep resumes

    @Test("sleep(milliseconds:) resumes (a zero delay completes)")
    func systemClockSleepReturns() async {
        await makeSut().sleep(milliseconds: 0)
        // Reaching here after the awaited sleep is the assertion: the call resumed rather than
        // hanging. Elapsed time is intentionally NOT measured (NFR21).
        #expect(Bool(true))
    }
}
