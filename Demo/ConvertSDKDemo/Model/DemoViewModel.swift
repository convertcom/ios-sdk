import ConvertSDK
import Network
import SwiftUI

/// App-level state for the Convert SDK demo.
///
/// Owns the single ``ConvertSDK`` instance (keeping the SDK out of the App struct and any View's
/// value semantics) and publishes the ``ConfigState`` readiness machine, the sticky decisioning
/// ``context``, and the connectivity flag the UI observes. `@MainActor`. The state-machine,
/// reset-visitor, and connectivity logic live in the `DemoViewModel+Config.swift` extension.
@MainActor
final class DemoViewModel: ObservableObject {

    /// The single SDK instance, owned for the app's lifetime.
    ///
    /// `ConvertSDK` is `final class … Sendable`, so it is held directly with no
    /// `@unchecked` wrapper under `SWIFT_STRICT_CONCURRENCY: complete`.
    let sdk: ConvertSDK

    /// The exact ``ConvertConfiguration`` the SDK was built from, retained because there is no
    /// public config-snapshot accessor on ``ConvertSDK`` — the Config panel accessors (in
    /// `DemoViewModel+Config.swift`) read the demo's own copy. `let` (NOT `private`) so that
    /// cross-file extension reads it.
    let configuration: ConvertConfiguration

    /// Coarse readiness signal for the UI, driven by the ``ConfigState`` machine in `start()`.
    /// `internal` setter (not `private(set)`) because that driver is cross-file in
    /// `DemoViewModel+Config.swift` (like ``context``/``events``); no external code writes it.
    @Published var configState: ConfigState = .loading

    /// The two segments of the Event Inspector sheet (Story 7.2 / DEMO-3).
    ///
    /// `CaseIterable` + `Identifiable` so it drives a segmented `Picker` directly;
    /// the `title` is the visible segment label and the VoiceOver word.
    enum InspectorSegment: CaseIterable, Identifiable {
        /// The observed-events list.
        case events
        /// The live-log stream.
        case logs

        /// Stable identity for the `Picker` / `ForEach`.
        var id: Self { self }

        /// The segment's visible label, e.g. "Events" / "Logs".
        var title: String {
            switch self {
            case .events: return "Events"
            case .logs: return "Logs"
            }
        }
    }

    /// Whether the Event Inspector sheet is presented. Drives the sheet from any
    /// tab's toolbar button, so the presentation state survives tab switches
    /// instead of resetting per-tab (AC1).
    @Published var isInspectorPresented: Bool = false

    /// The Event Inspector segment last chosen by the user. Lives here — not in a
    /// per-present `@State` — so it PERSISTS across present/dismiss cycles and tab
    /// switches (AC1). It is deliberately never reset on dismiss.
    @Published var selectedSegment: InspectorSegment = .events

    /// A "a delivery just happened" signal the sheet observes to post the VoiceOver
    /// "delivered" announcement (AC4).
    ///
    /// Bumped to a fresh `UUID` by ``record(_:_:)`` ONLY when an `.apiQueueReleased`
    /// actually flips ≥1 ``InspectorEvent/Lifecycle/queued`` row to
    /// ``InspectorEvent/Lifecycle/delivered`` — never on a plain append, and never on
    /// a release that flipped nothing. The model only *signals*; the View layer
    /// (``EventInspectorSheet``) owns the actual `UIAccessibility.post` so this view
    /// model stays free of UIKit / `UIAccessibility`. The announcement is therefore
    /// NOT animation-gated: it fires on every real flip regardless of Reduce Motion.
    ///
    /// Setter is `internal` (not `private(set)`) because the sole writer —
    /// ``record(_:_:)`` — lives in the `DemoViewModel+Inspector.swift` extension. Swift
    /// `private`/`fileprivate` do NOT reach a same-type extension in a *different* file
    /// (per the access-control rules), so a write-capable level is required; `internal`
    /// is the tightest one the cross-file compiler accepts. No external code writes it
    /// (the View layer only reads it), so this is encapsulation-neutral.
    @Published var lastDeliveryAnnouncementID = UUID()

    /// The observed-events buffer the inspector's Events list renders, newest-first.
    ///
    /// Filled by ``startEventInspector()``'s subscription (Story 7.2 Task 3) and
    /// rendered by Task 4. Exposed read-only — only the event handler here mutates
    /// it. Bounded at ``inspectorEventCap`` newest rows.
    ///
    /// Setter is `internal` (not `private(set)`) because its sole mutator —
    /// ``record(_:_:)`` — lives in the `DemoViewModel+Inspector.swift` extension, and
    /// Swift `private` does not reach a same-type extension across files. `internal` is
    /// the tightest write-capable level here; the View layer only reads it.
    @Published var events: [InspectorEvent] = []

    /// Live subscription tokens for the Event Inspector, one per ``SystemEvent``
    /// case, held so ``stopEventInspector()`` can unsubscribe every one. Empty
    /// until ``startEventInspector()`` populates it; cleared on stop.
    ///
    /// Stored properties cannot live in an extension (Swift fixes each type's memory
    /// layout at its main declaration), so this stays on the type even though its only
    /// users — ``startEventInspector()`` / ``stopEventInspector()`` — moved to the
    /// `DemoViewModel+Inspector.swift` extension. It is `internal` (not `private`)
    /// because Swift `private` does not reach a same-type extension across files;
    /// `internal` is the tightest level the cross-file compiler accepts.
    var inspectorTokens: [EventListenerToken] = []

    /// Upper bound on ``events`` so the demo buffer can't grow without limit over a
    /// long session. On insert, the oldest rows past this many are trimmed from the
    /// tail (``events`` is newest-first, so the tail is the oldest).
    ///
    /// Stays on the type (extensions can't hold stored properties) and is `internal`
    /// (not `private`) so its reader ``record(_:_:)`` in the extension file can see it —
    /// Swift `private` does not cross files even for the same type.
    let inspectorEventCap = 200

    /// The current, reusable decisioning context every run-screen method buckets against.
    ///
    /// Constructed once in ``init()`` and reused so bucketing is sticky/deterministic across
    /// re-runs for the same visitor. `@Published` (not `lazy`) so ``resetVisitor()``'s context
    /// SWAP republishes and every observing screen re-renders. `Sendable`, so publishing it from
    /// this `@MainActor` type is concurrency-clean. `internal` setter (the swapper is cross-file —
    /// see the `DemoViewModel+Config.swift` header for the full republish + access rationale).
    @Published var context: ConvertContext

    /// The experience key the single-experience run targets.
    ///
    /// A known-good, unaudienced, active key from the committed FS-Test-Proj staging config,
    /// so a default context buckets it deterministically. A `nil` return is rendered as an
    /// actionable card, never a crash. `static let` (NOT `private`) so the
    /// `DemoViewModel+Config.swift` panel surfaces it across files (like ``absentVariableKey``).
    static let singleExperienceKey = "test-experience-ab-fullstack-4"

    /// The feature key the single-feature run targets.
    ///
    /// A REAL key from the committed FS-Test-Proj staging config (feature id `100334`),
    /// carrying the richest typed-variable spread there: `price` (float), `button-height`
    /// (integer), and `additionalData` (json). `static let` (NOT `private`) so the
    /// `DemoViewModel+Config.swift` panel surfaces it across files (like ``absentVariableKey``).
    static let singleFeatureKey = "feature-2"

    /// A variable name guaranteed NOT present on any feature in the config.
    ///
    /// Used by ``FeaturesView`` (a different file) to demonstrate the honest absent
    /// rendition: ``Feature/variable(_:as:)`` returns `nil` for an unknown key
    /// (FR22 — "unknown → nil, never a throw"), so the UI renders an explicit "absent" row
    /// rather than crashing or fabricating a value. `static let` (NOT `private`) so
    /// `FeaturesView` can read it across files.
    static let absentVariableKey = "__demo_absent_variable__"

    /// The result-card buffer the Experiences screen renders, newest-first.
    ///
    /// Each run prepends ``ResultCard/Item`` rows via ``prependResult(_:)`` (newest at
    /// index 0), mirroring the ``events`` buffer. Exposed read-only — only the run
    /// methods mutate it. Bounded at ``resultCardCap`` newest rows.
    @Published private(set) var resultCards: [ResultCard.Item] = []

    /// Upper bound on ``resultCards`` so repeated runs can't grow the buffer without
    /// limit; on insert, the oldest rows past this many are trimmed from the tail.
    private let resultCardCap = 20

    /// Features buffer the Features screen renders, newest-first. Mirrors ``resultCards``:
    /// read-only, bounded at ``featureCap``, mutated via ``prepend(_:into:cap:)``. The View
    /// keys `ForEach` on enumerated offset (not `id`) because `Feature.id` is `""` for
    /// `.disabled` and `key` collides across re-runs.
    @Published private(set) var evaluatedFeatures: [Feature] = []

    /// Upper bound on ``evaluatedFeatures``; oldest rows past it trimmed on insert.
    private let featureCap = 20

    /// Neutral empty-state note for the Features screen (`nil` when nothing to surface).
    /// Set by ``runFeatures()`` when the SDK returns `[]` (valid degraded outcome, not an error);
    /// cleared at the start of every ``runFeature()`` / ``runFeatures()`` call.
    @Published private(set) var featuresEmptyNote: String?

    // MARK: - Conversions (Story 7.5 / DEMO-5)

    /// Conversion-card buffer the Conversions screen renders, newest-first. Mirrors
    /// ``resultCards``: read-only, bounded, mutated only via ``prependConversion(_:)``.
    @Published private(set) var conversionCards: [ResultCard.Item] = []

    /// Upper bound on ``conversionCards`` (mirrors ``resultCardCap``); oldest rows past it trimmed on insert.
    private let conversionCardCap = 20

    /// Goal keys already converted for the CURRENT (sticky ``context``) visitor, so the
    /// screen renders a `.dedup` card rather than a second SDK call. `internal` (not
    /// `private`) so the extension's ``trackGoal()`` writes it across files; cleared by
    /// ``clearTrackedGoals()`` (Story 7.6's reset-visitor).
    var trackedGoalKeys: Set<String> = []

    /// The demo's known goal keys — the goal-existence pre-check standing in for the
    /// not-yet-built Story 7.6 live-config surface (no public SDK accessor exposes the
    /// snapshot). The member is the REAL FS-Test-Proj `button-primary-click` goal.
    static let knownGoalKeys: Set<String> = ["button-primary-click"]

    /// The goal the Track Goal button converts — a member of ``knownGoalKeys`` whose
    /// pre-check passes, reaching the real ``ConvertContext`` `trackConversion`.
    static let demoGoalKey = "button-primary-click"

    /// A goal key guaranteed ABSENT from ``knownGoalKeys`` (a collision-proof sentinel like
    /// ``absentVariableKey``), driving the red `.error` card WITHOUT an SDK call.
    static let unknownGoalKey = "__demo_unknown_goal__"

    // MARK: - Reset-visitor & connectivity (Story 7.6 / DEMO-6)
    // Stored state for the reset-visitor + connectivity features (stored props can't live in an
    // extension). Its methods AND the full access-control / `NWPathMonitor` strict-concurrency
    // rationale live in `DemoViewModel+Config.swift` — see that file's header.

    /// Masked id of the visitor from the most recent ``resetVisitor()`` (`nil` before any reset);
    /// PII-safe (prefix + ellipsis, never the full UUID), read by the Config screen.
    @Published var lastResetVisitorMasked: String?

    /// Whether the device has a satisfied network path (driven by ``pathMonitor``); defaults `true`.
    /// `internal` setter — the monitor callback that writes it is cross-file (see +Config header).
    @Published var isOnline = true

    /// Live runtime tracking flag for the Config toggle (Story 5.6). Seeded from
    /// ``ConvertConfiguration/networkTracking``; updated by ``setTracking(_:)`` via
    /// ``ConvertSDK/isTrackingEnabled()`` read-back. `internal` setter — writer is cross-file.
    @Published var isRuntimeTrackingEnabled: Bool

    /// The `NWPathMonitor` backing ``isOnline`` (touched only from the main actor) and the serial
    /// queue it delivers updates on (`start(queue:)` requires one). See the +Config header.
    let pathMonitor = NWPathMonitor()
    let pathMonitorQueue = DispatchQueue(label: "com.convert.demo.path-monitor")

    init() {
        // FS-Test-Proj staging: account 10035569 / project 10034190. The "account/project"
        // sdkKey form resolves to {apiConfigEndpoint}/config/10035569/10034190 on the default
        // CDN (cdn-4.convertexperiments.com/api/v1); no secret needed to compile + launch-init.
        configuration = ConvertConfiguration(sdkKey: "10035569/10034190")
        sdk = ConvertSDK(configuration: configuration)
        // Eager sticky context (was a `lazy var`; `@Published` needs a non-lazy stored property).
        context = sdk.createContext()
        // Seed the runtime toggle from the static init flag (networkTracking defaults true).
        isRuntimeTrackingEnabled = configuration.networkTracking
    }

    /// Presents the Event Inspector sheet from any tab's toolbar button.
    ///
    /// Sets only ``isInspectorPresented`` — ``selectedSegment`` is left untouched
    /// so the last-chosen segment survives the re-present (AC1). There is
    /// deliberately no matching reset on dismiss; preserving the segment across
    /// present/dismiss cycles IS the persistence requirement.
    func presentInspector() {
        isInspectorPresented = true
    }

    // MARK: - Experience runs (Story 7.3 / DEMO-4)

    /// Runs the single baseline experience and prepends one result card.
    ///
    /// `@MainActor` (inherited): the `await` on
    /// ``ConvertContext/runExperience(_:enableTracking:)`` suspends without blocking the
    /// main actor (the SDK works off-actor), then ``resultCards`` is mutated on the main
    /// actor. `enableTracking` is left at the SDK default (`true`) — never `false` — so
    /// the bucketing event reaches the Event Inspector (AC4).
    ///
    /// A `nil` return (missing snapshot / unknown key / ineligible visitor) is a valid
    /// degraded outcome surfaced as ONE actionable `.error` card with the verbatim Voice
    /// & Tone message and hint — never a force unwrap, never a crash.
    func runExperience() async {
        let variation = await context.runExperience(Self.singleExperienceKey)
        if let variation {
            prependResult(
                ResultCard.Item(
                    title: variation.experienceKey,
                    detail: "Variation \(variation.key)",
                    variationKey: variation.key,
                    variant: .success
                )
            )
        } else {
            prependResult(
                ResultCard.Item(
                    title: Self.singleExperienceKey,
                    detail: "No variation for experience `\(Self.singleExperienceKey)`.",
                    hint: "Check experience config or audience eligibility.",
                    variant: .error
                )
            )
        }
    }

    /// Runs every experience the config carries and prepends one card per variation.
    ///
    /// `@MainActor` (inherited): the `await` on
    /// ``ConvertContext/runExperiences(enableTracking:)`` suspends without blocking the
    /// main actor, then ``resultCards`` is mutated on the main actor. `enableTracking`
    /// stays at the SDK default (`true`) so each bucketing event reaches the Event
    /// Inspector (AC4). Each ``Variation`` is prepended in the array's natural order, so
    /// the batch lands as a contiguous newest-first group (the SDK's last experience on
    /// top); the ``resultCardCap`` trim applies once after the whole batch.
    ///
    /// An empty `[]` return (config still loading, or an ineligible visitor) is a valid
    /// degraded outcome surfaced as ONE `.error` card with the verbatim Voice & Tone
    /// not-ready message and no hint — never a crash.
    func runExperiences() async {
        let variations = await context.runExperiences()
        if variations.isEmpty {
            prependResult(
                ResultCard.Item(
                    title: "No variation",
                    detail: "No variation yet — SDK still loading config, or the visitor is ineligible.",
                    variant: .error
                )
            )
        } else {
            for variation in variations {
                prependResult(
                    ResultCard.Item(
                        title: variation.experienceKey,
                        detail: "Variation \(variation.key)",
                        variationKey: variation.key,
                        variant: .success
                    )
                )
            }
        }
    }

    // MARK: - Feature runs (Story 7.4 / DEMO-2)

    /// Resolves the single baseline feature and prepends it to ``evaluatedFeatures``.
    ///
    /// `@MainActor` (inherited): the `await` on ``ConvertContext/runFeature(_:)``
    /// suspends without blocking the main actor (the SDK works off-actor), then
    /// ``evaluatedFeatures`` is mutated on the main actor. `runFeature` takes no `enableTracking`
    /// parameter (Android parity); the carrying experience's bucketing event still reaches the
    /// Event Inspector (AC4).
    ///
    /// `runFeature` is NON-optional and never throws: a degraded outcome (missing snapshot /
    /// miss) comes back as a `.disabled` feature with no variables, which the View renders
    /// honestly as a disabled card. There is therefore no `nil`/error branch here — whatever
    /// is returned is prepended as-is. The stale ``featuresEmptyNote`` is cleared first.
    func runFeature() async {
        featuresEmptyNote = nil
        let feature = await context.runFeature(Self.singleFeatureKey)
        prepend(feature, into: &evaluatedFeatures, cap: featureCap)
    }

    /// Resolves every feature the config carries and prepends each to ``evaluatedFeatures``.
    ///
    /// `@MainActor` (inherited): the `await` on ``ConvertContext/runFeatures()``
    /// suspends without blocking the main actor, then ``evaluatedFeatures`` is mutated on the
    /// main actor. `runFeatures` takes no `enableTracking` parameter (Android parity); each
    /// carrying experience's bucketing event still reaches the Event Inspector (AC4). Each ``Feature``
    /// is prepended in the array's natural (config) order, so the batch lands as a contiguous
    /// newest-first group; the ``featureCap`` trim applies per insert.
    ///
    /// An empty `[]` return (config still loading, degraded, or an ineligible visitor) is a
    /// valid degraded outcome — NOT an error. It surfaces ONE neutral ``featuresEmptyNote``
    /// (rendered by the View as an empty-state message, never a `ResultCard` error card),
    /// leaving the buffer untouched. The stale note is cleared first so a non-empty run wins.
    func runFeatures() async {
        featuresEmptyNote = nil
        let features = await context.runFeatures()
        if features.isEmpty {
            featuresEmptyNote = "No features evaluated — SDK still loading config, or the visitor is ineligible."
        } else {
            for feature in features {
                prepend(feature, into: &evaluatedFeatures, cap: featureCap)
            }
        }
    }

    /// Prepends one result card (newest-first) and trims the tail past ``resultCardCap``.
    ///
    /// A thin, named adapter over the generic ``prepend(_:into:cap:)`` so the experience run
    /// methods read as `prependResult(card)` while the actual insert/trim lives in ONE place
    /// shared with the feature buffer (DRY — no duplicated buffer-management block).
    private func prependResult(_ card: ResultCard.Item) {
        prepend(card, into: &resultCards, cap: resultCardCap)
    }

    /// Prepends one conversion card (newest-first) via ``prepend(_:into:cap:)``, like
    /// ``prependResult(_:)``. `internal` (not `private`) so it is the write-capable hop
    /// the `DemoViewModel+Conversions.swift` extension uses to mutate the `private(set)`
    /// ``conversionCards`` across files (mirroring ``record(_:_:)`` for ``events``).
    func prependConversion(_ card: ResultCard.Item) {
        prepend(card, into: &conversionCards, cap: conversionCardCap)
    }

    /// The single newest-first insert/trim implementation, shared by every bounded buffer
    /// (``resultCards``, ``evaluatedFeatures``, and ``conversionCards``).
    ///
    /// Inserts `element` at index 0 (newest-first), then drops the oldest rows past `cap`
    /// from the tail — mirroring how ``record(_:_:)`` maintains ``events``. Generic over the
    /// element type so neither caller copies the block: the experience path passes
    /// ``ResultCard/Item`` and the feature path passes ``Feature``.
    private func prepend<Element>(_ element: Element, into buffer: inout [Element], cap: Int) {
        buffer.insert(element, at: 0)
        if buffer.count > cap {
            buffer.removeLast(buffer.count - cap)
        }
    }
}
