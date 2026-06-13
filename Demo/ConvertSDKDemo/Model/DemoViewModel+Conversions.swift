import ConvertSDK
import SwiftUI

// MARK: - Conversion tracking (Story 7.5 / DEMO-5)

// This extension holds the conversion-tracking METHODS for ``DemoViewModel``. The
// matching stored state — the ``DemoViewModel/conversionCards`` buffer, its
// ``DemoViewModel/conversionCardCap`` bound, the per-visitor
// ``DemoViewModel/trackedGoalKeys`` set, and the ``DemoViewModel/knownGoalKeys`` /
// ``DemoViewModel/demoGoalKey`` / ``DemoViewModel/unknownGoalKey`` key constants —
// stays on the main type because Swift fixes each type's memory layout at its main
// declaration, so stored properties cannot live in an extension. The methods moved
// here purely to keep `DemoViewModel.swift` under the 400-line `file_length` gate;
// they reach back into the main type's state exactly as `DemoViewModel+Inspector`'s
// methods do.
//
// Access note: the buffer is `private(set)` and `prepend(_:into:cap:)` is `private`,
// and Swift `private` does not reach a same-type extension in a *different* file, so
// these methods never touch either directly. They write the buffer ONLY through the
// `internal` ``DemoViewModel/prependConversion(_:)`` hop on the main type — the same
// indirection ``DemoViewModel/record(_:_:)`` uses for `events`. The
// ``DemoViewModel/trackedGoalKeys`` set is likewise `internal` (not `private`) so
// ``trackGoal()`` here can mutate it across files.

extension DemoViewModel {

    /// Tracks the demo's known goal with a sample revenue amount, honoring the
    /// success → dedup → goal-not-found honesty contract.
    ///
    /// Three branches, in order:
    /// 1. **Pre-check existence** against ``knownGoalKeys`` — the SDK cannot tell the
    ///    demo "not found" (``ConvertContext/trackConversion(_:goalData:forceMultipleTransactions:)``
    ///    is non-throwing and silently WARN-drops an unknown goal), so the demo
    ///    pre-checks and renders a red `.error` card itself rather than show a false
    ///    success for a dropped goal.
    /// 2. **Dedup** — a repeat conversion for the same goal+visitor shows a `.dedup`
    ///    card and fires NO second SDK call. The SDK would dedup it internally anyway
    ///    (and returns Void either way, so the demo can't observe that from the call);
    ///    the demo surfaces the dedup honestly via its own ``trackedGoalKeys`` set.
    /// 3. **First trigger** — calls the real, non-throwing `trackConversion` on the
    ///    sticky ``context`` with a sample `.amount`, records the goal in
    ///    ``trackedGoalKeys``, and prepends the `.success` card with the amount.
    ///
    /// `@MainActor` (inherited): the `await` suspends without blocking the main actor
    /// (the SDK works off-actor), then the buffer is mutated on the main actor via the
    /// ``prependConversion(_:)`` hop. The sample amount is a `Double` literal whose
    /// interpolation renders as "49.99" — no force unwrap, no formatter needed.
    func trackGoal() async {
        // 1. PRE-CHECK existence against the demo's known-goal set (the SDK cannot tell
        //    us "not found" — trackConversion is non-throwing and drops silently). For
        //    ``demoGoalKey`` this guard always passes (it is by construction a member of
        //    ``knownGoalKeys``), so the Track Goal button never shows an error from here —
        //    ``trackUnknownGoal()`` demonstrates the goal-not-found card separately. The
        //    guard is retained so the pre-check pattern is visible AND so that if
        //    ``knownGoalKeys`` ever drops ``demoGoalKey`` the demo degrades honestly rather
        //    than show a false success for a goal the SDK would silently drop.
        guard Self.knownGoalKeys.contains(Self.demoGoalKey) else {
            prependConversion(
                ResultCard.Item(
                    title: "Goal not found: `\(Self.demoGoalKey)`",
                    detail: "Goal not found: `\(Self.demoGoalKey)`.",
                    hint: "Verify the goal is configured in your Convert project.",
                    variant: .error
                )
            )
            return
        }
        // 2. DEDUP: a repeat conversion for the same goal+visitor shows a dedup card and
        //    fires NO second SDK call (the SDK would dedup it anyway; the demo surfaces it).
        if trackedGoalKeys.contains(Self.demoGoalKey) {
            prependConversion(
                ResultCard.Item(
                    title: Self.demoGoalKey,
                    detail: "Conversion already tracked (dedup)",
                    variant: .dedup
                )
            )
            return
        }
        // 3. FIRST trigger: call the real, non-throwing trackConversion with a sample amount,
        //    record the visitor+goal, and show the success card with the amount.
        let amount = 49.99
        let data: GoalData = [.amount: .double(amount)]
        await context.trackConversion(Self.demoGoalKey, goalData: data)
        trackedGoalKeys.insert(Self.demoGoalKey)
        prependConversion(
            ResultCard.Item(
                title: Self.demoGoalKey,
                detail: "Conversion `\(Self.demoGoalKey)` · amount \(amount)",
                variant: .success
            )
        )
    }

    /// Demonstrates the goal-not-found honesty — pre-checks an absent key and renders
    /// the red `.error` card WITHOUT ever calling the SDK.
    ///
    /// Because the SDK silently WARN-drops an unknown goal (Void return, no signal), a
    /// real call would surface nothing — so the demo never shows a false success for a
    /// goal the SDK would drop. ``unknownGoalKey`` is, by construction, never in
    /// ``knownGoalKeys``, so the `guard` always takes the `.error` path and the SDK is
    /// never called. The fall-through after the `guard` exists only so that if a future
    /// config promoted that key into ``knownGoalKeys``, the demo would track it for real
    /// rather than fabricate an outcome — it is unreachable today.
    func trackUnknownGoal() async {
        guard Self.knownGoalKeys.contains(Self.unknownGoalKey) else {
            prependConversion(
                ResultCard.Item(
                    title: "Goal not found: `\(Self.unknownGoalKey)`",
                    detail: "Goal not found: `\(Self.unknownGoalKey)`.",
                    hint: "Verify the goal is configured in your Convert project.",
                    variant: .error
                )
            )
            return
        }
        // Unreachable by construction (unknownGoalKey is never in knownGoalKeys), but if a
        // future config added it, fall through to a real conversion rather than fabricate.
        await context.trackConversion(Self.unknownGoalKey)
    }

    /// Clears the per-visitor dedup set so the same goal can be tracked fresh for a new
    /// visitor.
    ///
    /// Story 7.6's reset-visitor affordance will call this when it rolls a new visitor on
    /// the sticky ``context``; this story only EXPOSES the hook. Building the
    /// reset-visitor UI is out of scope (Story 7.6). Synchronous and `@MainActor`
    /// (inherited): it only mutates ``trackedGoalKeys`` on the main actor.
    func clearTrackedGoals() {
        trackedGoalKeys.removeAll()
    }
}
