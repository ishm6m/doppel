import SwiftUI
import DoppelKit

/// Three-column shell (UI_SPEC.md §1). Real content lands in Milestone 4.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sidebarSelection: SidebarItem? = .sources

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Section("Library") {
                    Label("Sources", systemImage: "folder")
                        .tag(SidebarItem.sources)
                    Label("Scans", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarItem.scans)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            ContentPlaceholder()
                .navigationTitle(AppInfo.productName)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            // Wired in Milestone 4 (T4.3)
                        } label: {
                            Label("Scan", systemImage: "magnifyingglass")
                        }
                    }
                }
        } detail: {
            InspectorPlaceholder()
        }
    }
}

enum SidebarItem: Hashable { case sources, scans }

private struct ContentPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label("Choose folders to find duplicates", systemImage: "folder.badge.plus")
        } description: {
            Text("Everything stays on your Mac. Nothing is ever uploaded.")
        } actions: {
            Button("Choose Folders…") { /* T4.2 */ }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct InspectorPlaceholder: View {
    var body: some View {
        Text("Select a group to see details")
            .foregroundStyle(.secondary)
    }
}

struct SettingsPlaceholderView: View {
    var body: some View {
        Form {
            Text("Settings arrive in Milestone 6.")
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 320)
    }
}

#Preview {
    RootView().environment(AppEnvironment.preview())
}
