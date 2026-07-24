import ConvertSwiftSDK
import Foundation
import os

// MARK: - Experiment preview deep links (qs-02 / qs-03 host-app wiring)

// This extension is the host-app-owned deep-link wiring the qs-02/qs-03 quick-spec explicitly
// scopes OUT of the SDK ("No link registration inside the SDK — host-app concern"). It receives
// whatever URL SwiftUI's `.onOpenURL` (wired in `ConvertSwiftSDKDemoApp.swift`) hands it, and is
// the ONLY place in the demo that calls the pure `PreviewParam.parse` helper and
// `ConvertContext.setPreview(experienceId:variationId:)`. See the README "Testing
// experiment-preview deep links" section for the end-to-end `simctl openurl` test.
//
// Logging: the demo has no existing print/os_log convention (verified — no other file in
// `Demo/ConvertSwiftSDKDemo` logs anything), so this introduces `os.Logger` (unified logging,
// iOS 14+, safe on the iOS 15 floor) scoped to its own subsystem/category so the applied/ignored
// outcome is independently verifiable via `xcrun simctl spawn booted log stream` without needing
// Xcode attached to the process.
extension DemoViewModel {

    /// The unified-logging handle for preview-link diagnostics.
    ///
    /// A dedicated subsystem (the demo's bundle id) + category (`"preview-link"`) so a log
    /// stream can filter to exactly these lines; see the README for the exact `log stream`
    /// predicate.
    private static let previewLogger = Logger(subsystem: "com.convert.ConvertSwiftSDKDemo", category: "preview-link")

    /// Applies an incoming experiment-preview deep link.
    ///
    /// Wired from `ConvertSwiftSDKDemoApp.swift`'s `.onOpenURL`. Extracts the `convert_preview`
    /// query item, parses it with the SDK's pure ``PreviewParam/parse(_:)`` helper, and — on a
    /// successful parse — forces that variation via
    /// ``ConvertContext/setPreview(experienceId:variationId:)`` on the sticky ``context``, then
    /// re-runs every experience so the forced result appears on the Experiences screen exactly
    /// like any other run.
    ///
    /// Fully inert on a missing or malformed `convert_preview` value: logs the reason and returns
    /// without touching ``context``, ``resultCards``, or any other published state — a malformed
    /// or absent link can never corrupt the demo's decisioning state.
    ///
    /// `@MainActor` (inherited): `URLComponents` construction and ``PreviewParam/parse(_:)`` are
    /// synchronous; the two SDK calls (`setPreview`, ``runExperiences()``) `await` without
    /// blocking the main actor.
    func applyPreviewLink(_ url: URL) async {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let rawValue = components.queryItems?.first(where: { $0.name == "convert_preview" })?.value
        else {
            Self.previewLogger.notice("[preview-link] ignored: no convert_preview query item")
            return
        }

        guard let parsed = PreviewParam.parse(rawValue) else {
            Self.previewLogger.notice(
                "[preview-link] ignored: malformed convert_preview value \(rawValue, privacy: .public)"
            )
            return
        }

        await context.setPreview(experienceId: parsed.experienceId, variationId: parsed.variationId)
        // Built as a plain `String` first (rather than one long `Logger.notice` string
        // interpolation) because `OSLogMessage` interpolations cannot be split across a `+`
        // concatenation — the whole message must be a single literal. Wrapping the finished
        // string in one `\(…, privacy: .public)` interpolation keeps the log line under the
        // line-length limit without losing the per-value privacy annotation semantics.
        let appliedMessage = "[preview-link] applied exp=\(parsed.experienceId) var=\(parsed.variationId)"
        Self.previewLogger.notice("\(appliedMessage, privacy: .public)")
        await runExperiences()
    }
}
