import DetectionEngine
import DoppelCore
import DoppelKit
import SwiftUI

/// Three-column shell (UI_SPEC.md §1). First real vertical slice (M4): pick folders → scan →
/// groups stream into the results list. Member rows, per-group sizes, inspector detail, and
/// history land in later T4.x tasks.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sidebarSelection: SidebarItem? = .sources
    @State private var scanTask: Task<Void, Never>?
    @State private var showImporter = false
    @State private var scanError: String?
    /// File ids the user has checked for deletion. Never pre-populated (golden rule 3).
    @State private var selection: Set<Int64> = []
    @State private var showTrashConfirm = false

    private var scanService: ScanService {
        env.scanService
    }

    private var isScanning: Bool {
        scanTask != nil
    }

    /// FileRecords currently selected for deletion, in stable id order.
    private var selectedFiles: [FileRecord] {
        selection.sorted().compactMap { scanService.membersByID[$0] }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Section("Library") {
                    Label("Sources", systemImage: "folder").tag(SidebarItem.sources)
                    Label("Scans", systemImage: "clock.arrow.circlepath").tag(SidebarItem.scans)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            content
                .navigationTitle(AppInfo.productName)
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .bottom) { bulkActionBar }
                .sheet(isPresented: $showTrashConfirm) {
                    TrashConfirmSheet(files: selectedFiles) {
                        trashSelected()
                    } onCancel: {
                        showTrashConfirm = false
                    }
                }
        } detail: {
            InspectorPlaceholder()
        }
        .task {
            // Re-resolve remembered folders so they're scannable without re-prompting (T4.2).
            do { try await scanService.loadSources() } catch { scanError = error.localizedDescription }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result, !urls.isEmpty { addAndScan(urls) }
        }
        .alert("Scan failed", isPresented: .init(
            get: { scanError != nil },
            set: { if !$0 { scanError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scanError ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if isScanning {
            ScanProgressView(
                phase: scanService.phase,
                processed: scanService.processed,
                total: scanService.total,
                groups: scanService.groups,
                members: scanService.membersByID,
                selection: $selection
            )
        } else if !scanService.groups.isEmpty {
            ResultsList(groups: scanService.groups, members: scanService.membersByID, selection: $selection)
        } else if scanService.summary != nil {
            ContentUnavailableView("No duplicates found 🎉", systemImage: "checkmark.seal")
        } else if !scanService.sources.isEmpty {
            SourcesView(
                sources: scanService.sources,
                onScan: scanSources,
                onAdd: { showImporter = true },
                onRemove: removeSource
            )
        } else {
            ContentUnavailableView {
                Label("Choose folders to find duplicates", systemImage: "folder.badge.plus")
            } description: {
                Text("Everything stays on your Mac. Nothing is ever uploaded.")
            } actions: {
                Button("Choose Folders…") { showImporter = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if !isScanning, scanService.canUndoTrash {
            ToolbarItem(placement: .secondaryAction) {
                Button { undoTrash() } label: {
                    Label("Undo Delete", systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if isScanning {
                Button(role: .cancel) { scanTask?.cancel() } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
            } else {
                Button { showImporter = true } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
            }
        }
    }

    /// Bottom bar shown only when ≥1 file is checked (UI_SPEC.md §6 bulk action bar).
    @ViewBuilder private var bulkActionBar: some View {
        if !selection.isEmpty {
            HStack {
                Text("\(selection.count) selected")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Deselect") { selection = [] }
                Button("Move to Trash…", role: .destructive) { showTrashConfirm = true }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// Persist the picked folders as sources (so they survive relaunch), then scan them.
    private func addAndScan(_ urls: [URL]) {
        Task {
            do { try await scanService.addSources(urls) } catch { scanError = error.localizedDescription; return }
            scanSources()
        }
    }

    /// Scan every remembered source, tying the session to those sources' bookmark ids.
    private func scanSources() {
        let roots = scanService.sources.map(\.url)
        let bookmarkIDs = scanService.sources.map(\.id)
        guard !roots.isEmpty else { return }
        selection = []
        scanTask = Task {
            do {
                try await scanService.startScan(ScanRequest(roots: roots, scopes: [.document]), rootBookmarkIDs: bookmarkIDs)
            } catch is CancellationError {
                // Expected when the user hits Cancel; ScanService still finalizes the session.
            } catch {
                scanError = error.localizedDescription
            }
            scanTask = nil
        }
    }

    private func removeSource(_ id: Int64) {
        Task {
            do { try await scanService.removeSource(id: id) } catch { scanError = error.localizedDescription }
        }
    }

    private func trashSelected() {
        let ids = Array(selection)
        showTrashConfirm = false
        selection = []
        Task {
            do { try await scanService.trash(ids) } catch { scanError = error.localizedDescription }
        }
    }

    private func undoTrash() {
        Task {
            do { try await scanService.undoLastTrash() } catch { scanError = error.localizedDescription }
        }
    }
}

enum SidebarItem: Hashable { case sources, scans }

/// Remembered source folders (T4.2): the list persists across launches so the user re-scans without
/// re-picking. Add/remove here; scanning runs over all sources.
private struct SourcesView: View {
    let sources: [ScanService.Source]
    let onScan: () -> Void
    let onAdd: () -> Void
    let onRemove: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(sources) { source in
                HStack {
                    Label(source.displayPath, systemImage: "folder")
                        .truncationMode(.middle).lineLimit(1)
                    Spacer()
                    Button {
                        onRemove(source.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Forget this folder")
                }
            }
            HStack {
                Button("Add Folders…", action: onAdd)
                Spacer()
                Button("Scan", action: onScan)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}

/// Live scan header + groups as they arrive (UI_SPEC.md §5, F2). Determinate bar with a phase/count
/// label once counts are known; indeterminate during enumeration. Live groups + reclaimable counters.
private struct ScanProgressView: View {
    let phase: ScanPhase?
    let processed: Int
    let total: Int?
    let groups: [DuplicateGroup]
    let members: [Int64: FileRecord]
    @Binding var selection: Set<Int64>

    /// Space that would be freed if every non-keeper found so far were trashed (sum of their sizes).
    private var reclaimable: Int64 {
        groups.reduce(0) { acc, group in
            acc + group.memberFileIDs
                .filter { $0 != group.keeperFileID }
                .reduce(0) { $0 + (members[$1]?.sizeBytes ?? 0) }
        }
    }

    /// "Hashing 12 / 50" when countable, else the phase name, else a generic label.
    private var label: String {
        guard let phase else { return "Scanning…" }
        let name = phase.rawValue.capitalized
        if let total, total > 0 { return "\(name) \(processed.formatted()) / \(total.formatted())" }
        return name + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(label).font(.headline)
                    Spacer()
                    Text("\(groups.count) groups · \(reclaimable.formatted(.byteCount(style: .file))) reclaimable")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                // Determinate where countable (phase known + total>0); indeterminate during enumeration.
                if let total, total > 0, phase != nil {
                    ProgressView(value: Double(min(processed, total)), total: Double(total))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .padding(.horizontal)
            ResultsList(groups: groups, members: members, selection: $selection)
        }
        .padding(.top)
    }
}

/// Flat list of expandable GroupCards (UI_SPEC.md §6).
private struct ResultsList: View {
    let groups: [DuplicateGroup]
    let members: [Int64: FileRecord]
    @Binding var selection: Set<Int64>

    var body: some View {
        List(groups) { group in
            GroupCard(group: group, members: members, selection: $selection)
        }
    }
}

private struct GroupCard: View {
    let group: DuplicateGroup
    let members: [Int64: FileRecord]
    @Binding var selection: Set<Int64>
    @State private var isExpanded = false

    private var nonKeeperIDs: [Int64] {
        group.memberFileIDs.filter { $0 != group.keeperFileID }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Button("Select all but keeper") { selection.formUnion(nonKeeperIDs) }
                .font(.caption).buttonStyle(.link)
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
                        )
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
                Text("\(group.memberFileIDs.count) files")
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
/// suggested-keeper star, name/path, size. Interactive keeper-set arrives with T5.4.
private struct MemberRow: View {
    let file: FileRecord
    let isKeeper: Bool
    @Binding var isSelected: Bool

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
            Text(file.sizeBytes.formatted(.byteCount(style: .file)))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// Native confirmation before any deletion (UI_SPEC.md §9). Lists every affected file and the space
/// freed; the action is reversible (Trash), but we still always confirm (golden rule 3).
private struct TrashConfirmSheet: View {
    let files: [FileRecord]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var freed: Int64 {
        files.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move \(files.count) \(files.count == 1 ? "file" : "files") to Trash?")
                .font(.headline)
            Text("Frees \(freed.formatted(.byteCount(style: .file))). You can restore from the Trash.")
                .font(.subheadline).foregroundStyle(.secondary)
            List(files) { file in
                Label(file.relativePath, systemImage: "doc")
                    .truncationMode(.middle).lineLimit(1)
            }
            .frame(minHeight: 120, maxHeight: 240)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 460)
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
