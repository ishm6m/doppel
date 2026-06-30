import DoppelKit
import SwiftUI

/// First-launch onboarding (F10): sets the privacy expectation, then leads into folder selection.
/// Shown once — gated by the `onboardingComplete` AppStorage flag in RootView — and skippable.
struct OnboardingView: View {
    /// Called when the user finishes or skips; the host flips the persisted flag and (on finish) may
    /// kick off folder selection.
    let onFinish: (_ chooseFolders: Bool) -> Void
    @State private var page = 0

    private struct Page: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(
            symbol: "lock.shield",
            title: "Everything stays on your Mac",
            body: "\(AppInfo.productName) reads your files entirely on-device. "
                + "Nothing — no file, name, path, or fingerprint — is ever uploaded."
        ),
        Page(
            symbol: "doc.on.doc",
            title: "Finds real duplicates",
            body: "It understands content, not just names and sizes — so it catches the same "
                + "document saved twice, even with a different filename or a changed date."
        ),
        Page(
            symbol: "folder.badge.plus",
            title: "Choose folders to begin",
            body: "Pick the folders to scan. You stay in control: \(AppInfo.productName) only "
                + "ever suggests what to remove, and deletions go to the Trash."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: pages[page].symbol)
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(pages[page].title)
                    .font(.title).bold()
                    .multilineTextAlignment(.center)
                Text(pages[page].body)
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Spacer()
            // Page dots (decorative; the buttons drive navigation).
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle().fill(i == page ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            .padding(.bottom, 16)
            HStack {
                Button("Skip") { onFinish(false) }
                    .buttonStyle(.borderless)
                Spacer()
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Button(isLast ? "Choose Folders…" : "Next") {
                    if isLast { onFinish(true) } else { page += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520, height: 420)
    }

    private var isLast: Bool {
        page == pages.count - 1
    }
}

#Preview {
    OnboardingView { _ in }
}
