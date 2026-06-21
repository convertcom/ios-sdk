import SwiftUI

/// Adds the shared Event-Inspector toolbar button + placeholder sheet to a tab
/// shell's nav bar (Story 7.3 / DEMO-3).
///
/// All five tab shells need an identical trailing toolbar button that presents
/// the inspector sheet. Factoring it into one `ViewModifier` keeps the button,
/// its accessibility label, and the `.sheet` presentation in a single place
/// instead of repeating the block across every shell — the DRY /
/// copy-paste-detector discipline.
///
/// The presentation state now lives in ``DemoViewModel`` (read here via
/// `@EnvironmentObject`), NOT in a per-modifier `@State`. Because the modifier is
/// applied inside every tab's `NavigationView`, a private `@State` would be a
/// fresh copy per tab and would reset on every re-present; binding the sheet to
/// the shared view model is what makes the selected segment survive tab switches
/// and re-presents (AC1).
///
/// `.navigationBarTrailing` (not the iOS 17 `.topBarTrailing`) is used so the
/// placement compiles on the iOS 15 deployment floor.
private struct InspectorToolbar: ViewModifier {

    /// Shared app-level state, injected at the app root. Drives the inspector
    /// sheet presentation (``DemoViewModel/isInspectorPresented``) so it is one
    /// state across all tabs rather than a per-tab copy.
    @EnvironmentObject private var viewModel: DemoViewModel

    /// VoiceOver focus anchor for "return focus to the toolbar button on dismiss"
    /// (AC4).
    ///
    /// Bound to the inspector button via `.accessibilityFocused`. When the sheet
    /// closes (``DemoViewModel/isInspectorPresented`` flips to `false`), setting this
    /// `true` pulls VoiceOver focus back onto the button that opened the sheet,
    /// instead of leaving focus stranded at the top of the tab (a documented iOS
    /// sheet-dismissal quirk). This modifier is applied once per tab, so each tab
    /// owns its own anchor; only the on-screen tab's button is in the accessibility
    /// tree, so the off-screen tabs' identical request is a harmless no-op.
    @AccessibilityFocusState private var inspectorButtonFocused: Bool

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        viewModel.presentInspector()
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                            // Force the glyph's tap target to the 44pt a11y floor
                            // so the later a11y task (AC4) can rely on it; a
                            // toolbar button's hit area is often adequate already,
                            // but make it explicit rather than implicit.
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Event Inspector")
                    .accessibilityFocused($inspectorButtonFocused)
                }
            }
            .sheet(isPresented: $viewModel.isInspectorPresented) {
                EventInspectorSheet()
            }
            // Return VoiceOver focus to this button when the sheet dismisses (AC4).
            // Watching the shared presentation flag is how the toolbar learns the
            // sheet closed — whether via "Done", the grabber, or a swipe-down. Only
            // act on the false edge (closed); presenting already moves focus into the
            // sheet from `EventInspectorSheet` itself.
            .onChange(of: viewModel.isInspectorPresented) { isPresented in
                if !isPresented {
                    inspectorButtonFocused = true
                }
            }
    }
}

extension View {
    /// Attaches the Event-Inspector toolbar button and its placeholder sheet.
    ///
    /// Apply to the content inside each tab shell's `NavigationView` so the
    /// button lands on that shell's navigation bar. The sheet's presentation and
    /// selected-segment state live in the shared ``DemoViewModel`` (injected at
    /// the app root), so they persist across tab switches and re-presents rather
    /// than resetting per tab (AC1).
    func inspectorToolbar() -> some View {
        modifier(InspectorToolbar())
    }
}
