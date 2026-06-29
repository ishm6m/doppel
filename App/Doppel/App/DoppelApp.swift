import SwiftUI
import DoppelKit

@main
struct DoppelApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // Native menu commands are wired in Milestone 5 (undo) / 6 (scan ⌘R).
            CommandGroup(replacing: .help) {
                Link("\(AppInfo.productName) Help", destination: URL(string: "https://example.com")!)
            }
        }

        Settings {
            SettingsPlaceholderView() // Built in Milestone 6 (T6.2)
                .environment(environment)
        }
    }
}
