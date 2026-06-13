import SwiftUI

/// Placeholder for the Event-Inspector sheet (Story 7.3 / DEMO-3).
///
/// Every tab's nav bar carries an Event-Inspector toolbar button that presents
/// this sheet. The REAL inspector — a segmented Events / Logs view over the
/// SDK's emitted events and live logs — is Story 7.2 (`Inspector/EventInspectorSheet.swift`).
/// This stand-in keeps the toolbar button wired and dismissible today without
/// pre-empting that file.
///
/// It owns its own `NavigationView` (stack style) so the title and the Done
/// button render correctly inside a sheet on the iOS 15 floor, and reads
/// `\.dismiss` from the environment so the Done button closes the sheet
/// regardless of how it was presented.
struct InspectorPlaceholderView: View {

    /// Sheet dismissal handle, supplied by the presenting `.sheet` modifier.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: ConvertTheme.space3) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No events yet")
                    .font(.headline)
                Text("Run an experience or track a conversion to see events here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(ConvertTheme.space5)
            .navigationTitle("Event Inspector")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
