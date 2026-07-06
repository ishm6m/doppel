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

    /// Groups bucketed by match tier, in cheap→fuzzy order. Empty tiers are dropped so the user only
    /// sees kinds the scan actually found.
    private var tieredGroups: [(tier: MatchType, groups: [DuplicateGroup])] {
        let order: [MatchType] = [.exact, .nearText, .nearImage, .semantic]
        return order.compactMap { tier in
            let g = groups.filter { $0.matchType == tier }
            return g.isEmpty ? nil : (tier, g)
        }
    }

    /// "Identical — 2 groups · 5 files" section header for a tier bucket.
    private func tierHeader(_ tier: MatchType, _ g: [DuplicateGroup]) -> String {
        let files = g.reduce(0) { $0 + $1.memberFileIDs.count }
        return "\(MatchBadge.label(tier)) — \(g.count) group\(g.count == 1 ? "" : "s") · \(files) files"
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
                .padding(.horizontal).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if mode == .review, canReview {
                ReviewView(
                    groups: groups, members: members, selection: $selection,
                    onCompare: onCompare, onIgnore: onIgnore,
                    onSetKeeper: onSetKeeper!, onRequestTrash: onRequestTrash!
                )
            } else {
                List {
                    // At-a-glance payoff before the groups: reclaimable space (hero) + group/duplicate counts.
                    if !groups.isEmpty {
                        SummaryStrip(groups: groups, members: members)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
                            .listRowSeparator(.hidden)
                    }
                    // One-shot "clean it all up": pre-select every non-keeper across all groups and open
                    // the confirm sheet (which lists them + total freed) in one move. Never trashes without
                    // that confirm (golden rule 3); the keeper is always excluded. Only when we can trash
                    // (finished session, not a live scan). Its own Section so this global destructive action
                    // reads as a deliberate summary, not another group row you might hit by accident.
                    if allNonKeeperIDs.count > 1, let onRequestTrash {
                        Section {
                            Button(role: .destructive) {
                                selection = Set(allNonKeeperIDs)
                                onRequestTrash()
                            } label: {
                                Label(
                                    "Trash all \(allNonKeeperIDs.count) duplicates (keep starred)…",
                                    systemImage: "trash"
                                )
                            }
                            .help(
                                "Moves every file except the starred keeper in each group to the Trash. "
                                    + "You'll confirm the full list first."
                            )
                        }
                    }
                    // Grouped by match tier (Identical → Almost identical → Similar → Same meaning) so the
                    // safest, most-actionable duplicates lead and the user sees "what kind, how many" up front.
                    ForEach(tieredGroups, id: \.tier) { bucket in
                        Section(tierHeader(bucket.tier, bucket.groups)) {
                            ForEach(bucket.groups) { group in
                                GroupCard(
                                    group: group, members: members, selection: $selection,
                                    onCompare: onCompare, onIgnore: onIgnore
                                )
                            }
                        }
                    }
                    if !skipped.isEmpty {
                        SkippedSection(skipped: skipped, onReveal: onReveal)
                    }
                }
            }
        }
    }
}

/// Three-tile overview at the top of results: reclaimable space (the payoff, shown first and tinted),
/// group count, and total duplicate files. All derived from the loaded groups — no extra plumbing.
private struct SummaryStrip: View {
    let groups: [DuplicateGroup]
    let members: [Int64: FileRecord]

    private var reclaimable: Int64 {
        groups.flatMap(\.nonKeeperFileIDs).reduce(0) { $0 + (members[$1]?.sizeBytes ?? 0) }
    }

    private var duplicateCount: Int {
        groups.reduce(0) { $0 + $1.nonKeeperFileIDs.count }
    }

    var body: some View {
        HStack(spacing: 10) {
            tile(reclaimable.formatted(.byteCount(style: .file)), "Reclaimable", hero: true)
            tile("\(groups.count)", groups.count == 1 ? "Group" : "Groups", hero: false)
            tile("\(duplicateCount)", "Duplicate files", hero: false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(reclaimable.formatted(.byteCount(style: .file))) reclaimable across "
                + "\(groups.count) groups, \(duplicateCount) duplicate files."
        )
    }

    private func tile(_ value: String, _ label: String, hero: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(hero ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A group's scannable headline: the shared filename when every member has the same name, otherwise the
/// keeper's name + "+N" — far easier to read than a generic match description. Falls back to a neutral
/// label if members didn't load. Shared by the list card and the review pane so both read the same.
private func groupTitle(_ group: DuplicateGroup, _ members: [Int64: FileRecord]) -> String {
    let names = group.memberFileIDs.compactMap { members[$0]?.displayName }
    guard let first = names.first else { return "Duplicate group" }
    if Set(names).count == 1 { return first }
    let keeperName = members[group.keeperFileID]?.displayName ?? first
    let others = group.memberFileIDs.count - 1
    return others > 0 ? "\(keeperName) +\(others)" : keeperName
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(groupTitle(group, members))
                        .font(.title3.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    // Plain-language reason stays with the group (golden rule 4), now as the subtitle.
                    Text(group.explanation).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal).padding(.top, 4)

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
    @State private var isExpanded: Bool

    init(
        group: DuplicateGroup,
        members: [Int64: FileRecord],
        selection: Binding<Set<Int64>>,
        onCompare: @escaping (FileRecord, FileRecord) -> Void,
        onIgnore: @escaping (DuplicateGroup) -> Void
    ) {
        self.group = group
        self.members = members
        _selection = selection
        self.onCompare = onCompare
        self.onIgnore = onIgnore
        // Identical-content groups are the highest-confidence, most-actionable — open them on load;
        // near-dup / same-meaning groups start collapsed to keep the list scannable.
        _isExpanded = State(initialValue: group.matchType == .exact)
    }

    private var nonKeeperIDs: [Int64] {
        group.nonKeeperFileIDs
    }

    private var title: String { groupTitle(group, members) }

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

    /// Filename headline (easy to scan); the explanation stays as the secondary reason line so every
    /// group still carries its plain-language "why" (golden rule 4). Badge + size demoted below that.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Text(group.explanation).font(.caption).foregroundStyle(.secondary)
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
            "\(title). \(MatchBadge.label(group.matchType)), \(Int(group.confidence * 100)) percent confidence, "
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
            // Identical is certain by definition; a "% sure" tail there reads as doubt. Only show it
            // for the fuzzy tiers (near-dup / same-meaning) where confidence is a real signal.
            if group.matchType != .exact {
                Text("\(Int(group.confidence * 100))% sure")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
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
