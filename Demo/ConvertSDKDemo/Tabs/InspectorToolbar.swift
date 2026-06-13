import SwiftUI

/// Adds the shared Event-Inspector toolbar button + placeholder sheet to a tab
/// shell's nav bar (Story 7.3 / DEMO-3).
///
/// All five tab shells need an identical trailing toolbar button that presents
/// the inspector sheet. Factoring it into one `ViewModifier` keeps the button,
/// its accessibility label, the bound `@State`, and the `.sheet` presentation in
/// a single place instead of repeating the block across every shell — the DRY /
/// copy-paste-detector discipline.
///
/// `.navigationBarTrailing` (not the iOS 17 `.topBarTrailing`) is used so the
/// placement compiles on the iOS 15 deployment floor.
private struct InspectorToolbar: ViewModifier {

    /// Drives the inspector sheet presentation. Held here so each shell does not
    /// declare its own copy.
    @State private var showInspector = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showInspector = true
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel("Event Inspector")
                }
            }
            .sheet(isPresented: $showInspector) {
                InspectorPlaceholderView()
            }
    }
}

extension View {
    /// Attaches the Event-Inspector toolbar button and its placeholder sheet.
    ///
    /// Apply to the content inside each tab shell's `NavigationView` so the
    /// button lands on that shell's navigation bar.
    func inspectorToolbar() -> some View {
        modifier(InspectorToolbar())
    }
}
