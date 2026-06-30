import DoppelKit
import SwiftUI

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
            // Edit ▸ Undo Delete (⌘Z) restores the last trash from the Trash (F9). Fires
            // unconditionally — undoLastTrash() is a no-op when there's nothing to undo, which keeps
            // the command off the @Observable-in-commands tracking problem. (ponytail: a disabled-state
            // binding would need the env observed here; not worth it for a safe no-op.)
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Delete") {
                    Task { try? await environment.scanService.undoLastTrash() }
                }
                .keyboardShortcut("z", modifiers: .command)
            }
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
