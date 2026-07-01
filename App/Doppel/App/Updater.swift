import Combine
import Sparkle
import SwiftUI

/// The app's ONLY network touch-point (golden rule 1 / RELEASE.md §5): Sparkle's update controller.
/// Deliberately isolated in this one file so the entire egress surface is auditable at a glance and the
/// T8.4 guard can scope its exclusion here. The appcast feed URL and EdDSA public key live in Info.plist
/// (SUFeedURL / SUPublicEDKey); Sparkle verifies the appcast's signature before applying any update, and
/// only the signed Release build carries the network entitlement (Doppel.release.entitlements).
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    /// Mirrors Sparkle's readiness so the menu item disables itself mid-check.
    @Published var canCheckForUpdates = false

    init() {
        // startingUpdater: true → Sparkle runs its own scheduled background checks; the user can turn
        // those off in Sparkle's standard UI (RELEASE.md §5). No delegates: default behavior is correct.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// "Check for Updates…" menu item (under the app menu). Disabled while a check is already in flight.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: Updater
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
