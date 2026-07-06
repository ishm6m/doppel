import DoppelCore
import DoppelKit
import SwiftUI

/// Results, two ways to act on them (UI_SPEC §6):
/// - **List**: the full set as expandable cards with checkboxes + a bulk action bar (power path).
/// - **Review**: one group at a time — keep this, trash the rest, next (guided path). The review picker
///   only appears when the host wires the review closures (finished results), not during a live scan.
struct ResultsList: View {
    let groups: [DuplicateGroup]
    let members: [Int64: FileRecord]
    let skipped: [ScanService.SkippedFile]
    @Binding var selection: Set<Int64>
    let onCompare: (FileRecord, FileRecord) -> Void
    let onIgnore: (DuplicateGroup) -> Void
    let onReveal: (FileRecord) -> Void
    /// Change a group's keeper (guided review). Nil disables the Review path (e.g. during a live scan).
    var onSetKeeper: ((DuplicateGroup, Int64) -> Void)?
    /// Ask the host to trash whatever is in `selection` (routes through the shared confirm sheet).
    var onRequestTrash: (() -> Void)?

    @State private var mode: Mode = .list
    private enum Mode: String, CaseIterable { case list = "List", review = "Review" }

    /// Review is offered only when both review closures are present and there's a group to review.
    private var canReview: Bool {
        onSetKeeper != nil && onRequestTrash != nil && !groups.isEmpty
    }

    /// Every duplicate across every group (keepers excluded) — the "clean it all up" selection.
    private var allNonKeeperIDs: [Int64] {
        groups.flatMap(\.nonKeeperFileIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            if canReview {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, 6)
            }
            if mode == .review, canReview {
                ReviewView(
                    groups: groups, members: members, selection: $selection,
                    onCompare: onCompare, onIgnore: onIgnore,
                    onSetKeeper: onSetKeeper!, onRequestTrash: onRequestTrash!
                )
            } else {
                List {
                    // One-shot "keep one of each, check the rest" — collapses per-group selection into a
                    // single action. Never pre-checked (golden rule 3): the user taps it, then confirms via
                    // the shared trash sheet. The bottom bar's Deselect reverses it.
                    if allNonKeeperIDs.count > 1 {
                        Button {
                            selection = Set(allNonKeeperIDs)
                        } label: {
                            Label(
                                "Select all \(allNonKeeperIDs.count) duplicates (keep starred)",
                                systemImage: "checklist"
                            )
                        }
                        .help("Checks every file except the suggested keeper in each group. Confirm before it trashes anything.")
                    }
                    ForEach(groups) { group in
                        GroupCard(group: group, members: members, selection: $selection, onCompare: onCompare, onIgnore: onIgnore)
                    }
                    if !skipped.isEmpty {
                        SkippedSection(skipped: skipped, onReveal: onReveal)
                    }
                }
            }
        }
    }
}

/// Guided one-at-a-time review (F7/F8): the reassurance path behind "confidence to delete". Shows a
/// single group with its plain-language reason, the suggested keeper starred (tap another file's star to
/// keep that one instead), and three moves: mark not-duplicates, skip, or trash everything but the keeper.
/// Acting removes the group from `groups`, so the same index slides to the next one — no manual advance.
private struct ReviewView: View {
    let groups: [DuplicateGroup]
    let members: [Int64: FileRecord]
    @Binding var selection: Set<Int64>
    let onCompare: (FileRecord, FileRecord) -> Void
    let onIgnore: (DuplicateGroup) -> Void
    let onSetKeeper: (DuplicateGroup, Int64) -> Void
    let onRequestTrash: () -> Void
    @State private var index = 0

    private var clampedIndex: Int {
        min(index, max(0, groups.count - 1))
    }

    var body: some View {
        // groups can shrink under us as items are trashed/ignored; clamp and finish gracefully.
        if groups.isEmpty {
            ContentUnavailableView(
                "All reviewed 🎉",
                systemImage: "checkmark.seal",
                description: Text("You've been through every group.")
            )
        } else {
            let group = groups[clampedIndex]
            let nonKeeperIDs = group.nonKeeperFileIDs
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Group \(clampedIndex + 1) of \(groups.count)")
                        .font(.headline).monospacedDigit()
                    Spacer()
                    MatchBadge(group: group)
                }
                .padding(.horizontal).padding(.top, 4)

                Text(group.explanation)
                    .font(.title3).padding(.horizontal).padding(.top, 4)

                List {
                    ForEach(group.memberFileIDs, id: \.self) { id in
                        if let file = members[id] {
                            MemberRow(
                                file: file,
                                isKeeper: id == group.keeperFileID,
                                isSelected: .constant(false), // review uses the star, not checkboxes
                                showCheckbox: false,
                                onCompare: id == group.keeperFileID ? nil : members[group.keeperFileID].map { keeper in
                                    { onCompare(keeper, file) }
                                },
                                // Tap a non-keeper's star to keep it instead (the app's pick may be wrong).
                                onMakeKeeper: id == group.keeperFileID ? nil : { onSetKeeper(group, id) }
                            )
                        }
                    }
                }

                Divider()
                HStack {
                    Button("Not duplicates") { onIgnore(group) }
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Skip") { index = clampedIndex + 1 }
                        .disabled(clampedIndex + 1 >= groups.count)
                    Button("Move \(nonKeeperIDs.count) to Trash…", role: .destructive) {
                        selection = Set(nonKeeperIDs)
                        onRequestTrash()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(nonKeeperIDs.isEmpty)
                }
                .padding()
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
                            .accessibilityHidden(true) // decorative; the reason text conveys it
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.file.displayName)
                            Text(Self.reason(item.issue))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
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
        group.nonKeeperFileIDs
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
                        showCheckbox: true,
                        // Compare a non-keeper against the keeper — the "why did these match?" view (F8).
                        onCompare: id == group.keeperFileID ? nil : members[group.keeperFileID].map { keeper in
                            { onCompare(keeper, file) }
                        },
                        onMakeKeeper: nil
                    )
                }
            }
        } label: {
            header
        }
        .padding(.vertical, 4)
    }

    /// Reason first (golden rule 4), match type + confidence demoted to a quiet secondary line.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.explanation).font(.body)
            HStack(spacing: 8) {
                MatchBadge(group: group)
                Spacer()
                Text("\(group.memberFileIDs.count) files · \(reclaimable.formatted(.byteCount(style: .file))) reclaimable")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        // VoiceOver reads the whole group summary as one phrase (ACCESSIBILITY.md §1).
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(MatchBadge.label(group.matchType)), \(Int(group.confidence * 100)) percent confidence, "
                + "\(group.memberFileIDs.count) files, "
                + "\(reclaimable.formatted(.byteCount(style: .file))) reclaimable. \(group.explanation)"
        )
    }
}

/// The match kind as a friendly, coloured chip + a quiet confidence tail — plain words, not engine terms.
private struct MatchBadge: View {
    let group: DuplicateGroup

    var body: some View {
        HStack(spacing: 6) {
            Text(Self.label(group.matchType))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
            Text("\(Int(group.confidence * 100))% sure")
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    static func label(_ type: MatchType) -> String {
        switch type {
        case .exact: "Identical"
        case .nearText: "Almost identical"
        case .nearImage: "Similar image"
        case .semantic: "Same meaning"
        }
    }

    private var color: Color {
        switch group.matchType {
        case .exact: .green
        case .nearText: .blue
        case .nearImage: .purple
        case .semantic: .orange
        }
    }
}

/// One file within a group (UI_SPEC.md §6 member row): optional selection checkbox (never pre-checked),
/// suggested-keeper star (tappable in review to change the keeper), name/path, size.
private struct MemberRow: View {
    let file: FileRecord
    let isKeeper: Bool
    @Binding var isSelected: Bool
    var showCheckbox: Bool = true
    /// Opens the compare view against the keeper; nil for the keeper row itself.
    let onCompare: (() -> Void)?
    /// Tap the star to make this file the keeper (review mode); nil disables it (list mode / keeper row).
    var onMakeKeeper: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if showCheckbox {
                Toggle("Select \(file.displayName)", isOn: $isSelected)
                    .labelsHidden().toggleStyle(.checkbox)
            }
            star
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

    @ViewBuilder private var star: some View {
        let icon = Image(systemName: isKeeper ? "star.fill" : "star")
            .foregroundStyle(isKeeper ? .yellow : .secondary)
        if let onMakeKeeper {
            Button(action: onMakeKeeper) { icon }
                .buttonStyle(.borderless)
                .help(isKeeper ? "Suggested keeper" : "Keep this one instead")
                .accessibilityLabel(isKeeper ? "Suggested keeper" : "Keep this file instead")
        } else {
            icon
                .help(isKeeper ? "Suggested keeper" : "")
                .accessibilityLabel(isKeeper ? "Suggested keeper" : "")
                .accessibilityHidden(!isKeeper)
        }
    }
}
