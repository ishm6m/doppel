import DoppelCore
import DoppelKit
import SwiftUI

/// Expandable GroupCards plus a "Skipped (N)" section for files the scan couldn't process (UI_SPEC §6).
struct ResultsList: View {
    let groups: [DuplicateGroup]
    let members: [Int64: FileRecord]
    let skipped: [ScanService.SkippedFile]
    @Binding var selection: Set<Int64>
    let onCompare: (FileRecord, FileRecord) -> Void
    let onIgnore: (DuplicateGroup) -> Void
    let onReveal: (FileRecord) -> Void

    var body: some View {
        List {
            ForEach(groups) { group in
                GroupCard(group: group, members: members, selection: $selection, onCompare: onCompare, onIgnore: onIgnore)
            }
            if !skipped.isEmpty {
                SkippedSection(skipped: skipped, onReveal: onReveal)
            }
        }
    }
}

/// Collapsed-by-default list of files the scan couldn't process, each with a plain-language reason and
/// a Reveal-in-Finder action (T8.1 / ERROR_HANDLING.md). Never silently dropped, never fatal.
private struct SkippedSection: View {
    let skipped: [ScanService.SkippedFile]
    let onReveal: (FileRecord) -> Void

    var body: some View {
        Section {
            DisclosureGroup("Skipped (\(skipped.count))") {
                ForEach(skipped) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.file.displayName)
                            Text(Self.reason(item.issue))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reveal in Finder", systemImage: "magnifyingglass") { onReveal(item.file) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .help("Reveal in Finder")
                    }
                }
            }
            .font(.callout)
        }
    }

    /// Plain-language explanation per issue kind (ERROR_HANDLING.md §“Skipped”).
    private static func reason(_ issue: FileIssue) -> String {
        switch issue.kind {
        case .unreadable: "Couldn't be read"
        case .unsupported: "Unsupported file type"
        case .decodeFailed: "Couldn't read contents"
        case .tooLarge: "Too large to scan"
        case .permissionDenied: "Permission denied"
        case .needsOCR: "Scanned PDF — needs OCR to compare"
        }
    }
}

private struct GroupCard: View {
    let group: DuplicateGroup
    let members: [Int64: FileRecord]
    @Binding var selection: Set<Int64>
    let onCompare: (FileRecord, FileRecord) -> Void
    let onIgnore: (DuplicateGroup) -> Void
    @State private var isExpanded = false

    private var nonKeeperIDs: [Int64] {
        group.memberFileIDs.filter { $0 != group.keeperFileID }
    }

    /// Space freed if every non-keeper in this group is trashed (F7 per-group reclaimable size).
    private var reclaimable: Int64 {
        nonKeeperIDs.reduce(0) { $0 + (members[$1]?.sizeBytes ?? 0) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            HStack {
                Button("Select all but keeper") { selection.formUnion(nonKeeperIDs) }
                    .buttonStyle(.link)
                Spacer()
                // F7/F14: mark this set "not duplicates" — it leaves the list and won't recur.
                Button("Not duplicates") { onIgnore(group) }
                    .buttonStyle(.link).foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            // ponytail: rows resolve from the in-memory member map; a file we somehow didn't retain
            // is skipped rather than crashing. Member IDs are unique per scan, so order is stable.
            ForEach(group.memberFileIDs, id: \.self) { id in
                if let file = members[id] {
                    MemberRow(
                        file: file,
                        isKeeper: id == group.keeperFileID,
                        isSelected: Binding(
                            get: { selection.contains(id) },
                            set: { if $0 { selection.insert(id) } else { selection.remove(id) } }
                        ),
                        // Compare a non-keeper against the keeper — the "why did these match?" view (F8).
                        onCompare: id == group.keeperFileID ? nil : members[group.keeperFileID].map { keeper in
                            { onCompare(keeper, file) }
                        }
                    )
                }
            }
        } label: {
            header
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(badgeLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(badgeColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(badgeColor)
                Text("\(Int(group.confidence * 100))% confidence")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(group.memberFileIDs.count) files · \(reclaimable.formatted(.byteCount(style: .file))) reclaimable")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Golden rule 4: every group carries a human-readable reason.
            Text(group.explanation).font(.body)
        }
    }

    private var badgeLabel: String {
        switch group.matchType {
        case .exact: "Exact"
        case .nearText: "Near-duplicate"
        case .nearImage: "Similar image"
        case .semantic: "Semantic"
        }
    }

    private var badgeColor: Color {
        switch group.matchType {
        case .exact: .green
        case .nearText: .blue
        case .nearImage: .purple
        case .semantic: .orange
        }
    }
}

/// One file within a group (UI_SPEC.md §6 member row): selection checkbox (never pre-checked),
/// suggested-keeper star, name/path, size.
private struct MemberRow: View {
    let file: FileRecord
    let isKeeper: Bool
    @Binding var isSelected: Bool
    /// Opens the compare view against the keeper; nil for the keeper row itself.
    let onCompare: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Select \(file.displayName)", isOn: $isSelected)
                .labelsHidden().toggleStyle(.checkbox)
            Image(systemName: isKeeper ? "star.fill" : "doc")
                .foregroundStyle(isKeeper ? .yellow : .secondary)
                .help(isKeeper ? "Suggested keeper" : "")
            VStack(alignment: .leading, spacing: 1) {
                Text(file.displayName)
                Text(file.relativePath)
                    .font(.caption).foregroundStyle(.secondary)
                    .truncationMode(.middle).lineLimit(1)
            }
            Spacer()
            if let onCompare {
                Button("Compare", systemImage: "rectangle.split.2x1", action: onCompare)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Compare with the suggested keeper")
            }
            Text(file.sizeBytes.formatted(.byteCount(style: .file)))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
