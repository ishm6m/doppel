import DoppelCore
import SwiftUI

/// Persistent header: Add Folders on the left, the remembered folders as compact removable pills in a
/// scrolling middle strip, and the primary Scan action on the right. Sits directly under the toolbar in
/// every state and never moves. Pills are low-emphasis chips (not buttons) so they show what will be
/// scanned without competing with the primary actions.
struct HomeHeader: View {
    let sources: [ScanService.Source]
    let isScanning: Bool
    let canScan: Bool
    let onAdd: () -> Void
    let onRemove: (Int64) -> Void
    let onScan: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Add Folders…", systemImage: "plus", action: onAdd)
                .disabled(isScanning)
            // Many folders scroll rather than shoving Scan off-screen.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sources) { source in
                        FolderPill(
                            name: source.url.lastPathComponent,
                            isScanning: isScanning,
                            onRemove: { onRemove(source.id) }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Only offer Scan once folders exist; before that the primary action is Add Folders (and
            // the body shows the "Choose folders" CTA), so a greyed-out Scan would just be noise.
            if canScan {
                Button("Scan", action: onScan)
                    .buttonStyle(.borderedProminent)
                    .disabled(isScanning)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }
}

/// One remembered folder as a removable chip: folder glyph + name + an ✕ that drops it. Reads as a
/// status chip, not a button — the primary actions stay Add Folders / Scan.
private struct FolderPill: View {
    let name: String
    let isScanning: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder").font(.caption2).foregroundStyle(.secondary)
            Text(name).font(.callout).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isScanning)
            .help("Remove \(name)")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .fixedSize()
    }
}
