import DoppelKit
import SwiftUI

/// One scan-history row in the sidebar: folder-derived title (or custom name), a pin marker, a "Rescan"
/// badge when the folder changed since the scan, and a secondary line with the relative time + outcome.
struct SessionRow: View {
    let title: String
    let pinned: Bool
    let stale: Bool
    let session: ScanSession

    private var outcome: String {
        session.groupsFound == 0
            ? "Clean"
            : "\(session.groupsFound) group\(session.groupsFound == 1 ? "" : "s") · "
            + session.bytesReclaimable.formatted(.byteCount(style: .file))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                Text(title).lineLimit(1)
                if stale {
                    Text("Rescan")
                        .font(.caption2.weight(.medium)).foregroundStyle(.orange)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .help("Files in this folder changed since this scan.")
                }
            }
            Text(session.startedAt.formatted(.relative(presentation: .named)) + " · " + outcome)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .help("Reopen this scan of \(title)")
    }
}
