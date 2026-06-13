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
                }
            }
            .sheet(isPresented: $viewModel.isInspectorPresented) {
                EventInspectorSheet()
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
