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
    /// The keeper/other pair the user asked to compare (F8), shown in a sheet. Nil when closed.
    @State private var comparing: ComparePair?
    /// First-launch onboarding gate (F10): shown once, then persisted so it never reappears.
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    private var scanService: ScanService {
        env.scanService
    }

    private var isScanning: Bool {
        scanTask != nil
    }

    /// True when a scan (past or just-finished) is selected in the sidebar — drives the results view.
    private var isViewingSession: Bool {
        if case .session = sidebarSelection { return true }
        return false
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
                }
                if !scanService.sessions.isEmpty {
                    Section("Recent Scans") {
                        ForEach(scanService.sessions) { session in
                            SessionRow(session: session).tag(SidebarItem.session(session.id))
                        }
                    }
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
                .sheet(item: $comparing) { pair in
                    CompareView(pair: pair) { await scanService.compareTexts($0, $1) }
                }
                .sheet(isPresented: .init(get: { !onboardingComplete }, set: { if $0 { onboardingComplete = false } })) {
                    OnboardingView { chooseFolders in
                        onboardingComplete = true
                        if chooseFolders { showImporter = true }
                    }
                    .interactiveDismissDisabled()
                }
        } detail: {
            InspectorPlaceholder()
        }
        .task {
            // Re-resolve remembered folders so they're scannable without re-prompting (T4.2), and
            // load the scan history for the sidebar (T4.2/F12).
            do { try await scanService.loadSources() } catch { scanError = error.localizedDescription }
            await scanService.loadSessions()
        }
        .onChange(of: sidebarSelection) { _, selection in
            // Selecting a past scan reopens its results (F12).
            guard case let .session(id) = selection else { return }
            Task {
                do { try await scanService.openSession(id) } catch { scanError = error.localizedDescription }
            }
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
                skipped: scanService.skipped,
                selection: $selection,
                onCompare: compare,
                onIgnore: ignoreGroup,
                onReveal: revealInFinder
            )
        } else if isViewingSession {
            // A past (or just-finished) scan is selected: show its results, or the clean-bill state.
            if scanService.groups.isEmpty {
                ContentUnavailableView("No duplicates found 🎉", systemImage: "checkmark.seal")
            } else {
                ResultsList(
                    groups: scanService.groups,
                    members: scanService.membersByID,
                    skipped: scanService.skipped,
                    selection: $selection,
                    onCompare: compare,
                    onIgnore: ignoreGroup,
                    onReveal: revealInFinder
                )
            }
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
                // ⌘Z lives on the Edit ▸ Undo Delete menu command (DoppelApp); this is the visible
                // toolbar affordance, no shortcut, to avoid a double ⌘Z binding.
                Button { undoTrash() } label: {
                    Label("Undo Delete", systemImage: "arrow.uturn.backward")
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if isScanning {
                Button(role: .cancel) { scanTask?.cancel() } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
                .keyboardShortcut(.cancelAction) // ⎋ cancels (ACCESSIBILITY.md §2)
            } else {
                // ⌘R scans the remembered folders if any, else opens the picker (ACCESSIBILITY.md §2).
                Button { scanService.sources.isEmpty ? (showImporter = true) : scanSources() } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("r", modifiers: .command)
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
                // Scopes + thresholds come from Settings (F11), so a settings change takes effect here.
                let request = ScanRequest(roots: roots, scopes: DetectionSettings.scopes, config: DetectionSettings.config)
                let id = try await scanService.startScan(request, rootBookmarkIDs: bookmarkIDs)
                // The finished scan becomes the selected history entry, so its results stay on screen.
                sidebarSelection = .session(id)
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

    private func compare(_ keeper: FileRecord, _ other: FileRecord) {
        comparing = ComparePair(keeper: keeper, other: other)
    }

    private func ignoreGroup(_ group: DuplicateGroup) {
        Task {
            do { try await scanService.ignore(group) } catch { scanError = error.localizedDescription }
        }
    }

    /// Reveal a skipped file in Finder (T8.1). SwiftUI has no equivalent, so we reach for NSWorkspace.
    private func revealInFinder(_ file: FileRecord) {
        guard let url = scanService.absoluteURL(for: file) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

enum SidebarItem: Hashable {
    case sources
    case session(Int64)
}

/// One past scan in the history sidebar (F12): when it ran + what it found.
private struct SessionRow: View {
    let session: ScanSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .lineLimit(1)
            Text("\(session.groupsFound) group\(session.groupsFound == 1 ? "" : "s") · "
                + session.bytesReclaimable.formatted(.byteCount(style: .file)))
                .font(.caption).foregroundStyle(.secondary)
        }
        .help("Reopen this scan")
    }
}

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
    let skipped: [ScanService.SkippedFile]
    @Binding var selection: Set<Int64>
    let onCompare: (FileRecord, FileRecord) -> Void
    let onIgnore: (DuplicateGroup) -> Void
    let onReveal: (FileRecord) -> Void

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
            ResultsList(
                groups: groups, members: members, skipped: skipped, selection: $selection,
                onCompare: onCompare, onIgnore: onIgnore, onReveal: onReveal
            )
        }
        .padding(.top)
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

#Preview {
    RootView().environment(AppEnvironment.preview())
}
