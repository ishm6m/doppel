import DetectionEngine
import DoppelCore
import DoppelKit
import SwiftUI

/// Three-column shell (UI_SPEC.md §1). First real vertical slice (M4): pick folders → scan →
/// groups stream into the results list. Member rows, per-group sizes, inspector detail, and
/// history land in later T4.x tasks.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sidebarSelection: SidebarItem? = .home
    @State private var scanTask: Task<Void, Never>?
    @State private var showImporter = false
    @State private var scanError: String?
    /// File ids the user has checked for deletion. Never pre-populated (golden rule 3).
    @State private var selection: Set<Int64> = []
    @State private var showTrashConfirm = false
    /// Gate for the opt-in "Deep scan" (F6/T7.3): a confirmation carrying the battery note, so the
    /// expensive semantic tier only ever runs on a deliberate, informed action.
    @State private var showDeepScanConfirm = false
    /// The keeper/other pair the user asked to compare (F8), shown in a sheet. Nil when closed.
    @State private var comparing: ComparePair?
    /// First-launch onboarding gate (F10): shown once, then persisted so it never reappears.
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    /// The session being renamed (drives the rename alert), plus its editable name buffer.
    @State private var renamingSession: Int64?
    @State private var renameText = ""

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
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                Section("Scans") {
                    if scanService.sessions.isEmpty {
                        Text("Run a scan to see it here.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(scanService.sessions) { session in
                            SessionRow(
                                title: session.name ?? folderLabel(for: session),
                                pinned: session.pinned,
                                stale: scanService.staleSessionIDs.contains(session.id),
                                session: session
                            )
                            .tag(SidebarItem.session(session.id))
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) { forgetSession(session.id) }
                            }
                            .contextMenu {
                                Button("Rename…") { beginRename(session) }
                                Button(session.pinned ? "Unpin" : "Pin") { togglePin(session) }
                                Divider()
                                Button("Delete", role: .destructive) { forgetSession(session.id) }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
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
                .sheet(isPresented: .init(get: { !onboardingComplete }, set: { onboardingComplete = !$0 })) {
                    OnboardingView { chooseFolders in
                        onboardingComplete = true
                        if chooseFolders { showImporter = true }
                    }
                    .interactiveDismissDisabled()
                }
                .confirmationDialog("Run a deep scan?", isPresented: $showDeepScanConfirm, titleVisibility: .visible) {
                    Button("Run Deep Scan") { runScan(deepScan: true) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Deep scan reads the meaning of your documents with an on-device model to catch "
                        + "same-meaning rewrites the fast scan misses. It's slower and uses more energy — "
                        + "best run while plugged in. Nothing leaves your Mac.")
                }
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
        .alert("Rename Scan", isPresented: .init(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave blank to show the scanned folder name.")
        }
    }

    /// One continuous pane with a fixed hierarchy: a persistent header (Add Folders + Scan) pinned
    /// directly under the toolbar, a divider, and a content region that always fills the rest. Only
    /// `bodyRegion`'s empty states center themselves — the header never moves between states.
    private var content: some View {
        VStack(spacing: 0) {
            HomeHeader(
                isScanning: isScanning,
                canScan: !scanService.sources.isEmpty,
                onAdd: { showImporter = true },
                onScan: scanSources
            )
            Divider()
            bodyRegion
                // Pin the header top-down: the region owns all remaining height, so a centered
                // empty state centers inside *this*, never dragging the header to the middle.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var bodyRegion: some View {
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
                    onReveal: revealInFinder,
                    onSetKeeper: setKeeper,
                    onRequestTrash: { showTrashConfirm = true }
                )
            }
        } else if scanService.sources.isEmpty {
            // First run: no folders chosen yet.
            ContentUnavailableView {
                Label("Choose folders to find duplicates", systemImage: "folder.badge.plus")
            } description: {
                Text("Everything stays on your Mac. Nothing is ever uploaded.")
            } actions: {
                Button("Choose Folders…") { showImporter = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            // Folders are added but nothing scanned yet.
            ContentUnavailableView {
                Label("Ready to scan", systemImage: "magnifyingglass")
            } description: {
                Text("Scan your folders to find duplicate documents. Everything stays on your Mac.")
            } actions: {
                Button("Scan") { scanSources() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if !isScanning, !scanService.sources.isEmpty, env.embedding.isSemantic {
            ToolbarItem(placement: .secondaryAction) {
                // Opt-in semantic tier (F6/T7.3). Hidden until a real model is pinned (T7.4) so the
                // stub's non-meaningful vectors never surface as "semantic" matches. Confirms first
                // (battery note) so it never runs by surprise.
                Button { showDeepScanConfirm = true } label: {
                    Label("Deep Scan", systemImage: "sparkle.magnifyingglass")
                }
                .help("Find same-meaning documents using an on-device model. Slower; best while plugged in.")
            }
        }
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

    /// Zero-arg entry for ⌘R and the Scan button: a normal (fast) cascade, no embedding.
    private func scanSources() {
        runScan(deepScan: false)
    }

    /// The folder names a past scan covered, e.g. "Downloads" or "Downloads +2" — the human-memorable
    /// identity of a scan (a timestamp isn't). Falls back to "Folders" if the sources are no longer remembered.
    private func folderLabel(for session: ScanSession) -> String {
        let names = session.rootBookmarkIDs.compactMap { id in
            scanService.sources.first { $0.id == id }.map { URL(fileURLWithPath: $0.displayPath).lastPathComponent }
        }
        guard let first = names.first else { return "Folders" }
        return names.count > 1 ? "\(first) +\(names.count - 1)" : first
    }

    /// Forget a past scan from history (files untouched). If it was the open one, fall back to Home.
    private func forgetSession(_ id: Int64) {
        if sidebarSelection == .session(id) { sidebarSelection = .home }
        Task {
            do { try await scanService.deleteSession(id) } catch { scanError = error.localizedDescription }
        }
    }

    /// Seed the rename buffer with the current custom name (empty if none) and open the rename alert.
    private func beginRename(_ session: ScanSession) {
        renameText = session.name ?? ""
        renamingSession = session.id
    }

    private func commitRename() {
        guard let id = renamingSession else { return }
        let name = renameText
        renamingSession = nil
        Task {
            do { try await scanService.renameSession(id, to: name) } catch { scanError = error.localizedDescription }
        }
    }

    private func togglePin(_ session: ScanSession) {
        Task {
            do { try await scanService.setPinned(session.id, !session.pinned) } catch {
                scanError = error.localizedDescription
            }
        }
    }

    /// Scan every remembered source, tying the session to those sources' bookmark ids. `deepScan` turns
    /// on the opt-in semantic tier (F6) for this run only — it's an explicit action, never a persisted default.
    private func runScan(deepScan: Bool) {
        let roots = scanService.sources.map(\.url)
        let bookmarkIDs = scanService.sources.map(\.id)
        guard !roots.isEmpty else { return }
        selection = []
        scanTask = Task {
            do {
                // Scopes + thresholds come from Settings (F11), so a settings change takes effect here.
                var config = DetectionSettings.config
                config.deepScan = deepScan
                let request = ScanRequest(roots: roots, scopes: DetectionSettings.scopes, config: config)
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

    private func compare(_ keeper: FileRecord, _ other: FileRecord) {
        comparing = ComparePair(keeper: keeper, other: other)
    }

    private func ignoreGroup(_ group: DuplicateGroup) {
        Task {
            do { try await scanService.ignore(group) } catch { scanError = error.localizedDescription }
        }
    }

    /// Guided review: keep a different file than the one the app suggested (F7).
    private func setKeeper(_ group: DuplicateGroup, _ fileID: Int64) {
        Task {
            do { try await scanService.setKeeper(groupID: group.id, fileID: fileID) } catch { scanError = error.localizedDescription }
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
    case home
    case session(Int64)
}

/// One past scan in the history sidebar (F12). Leads with its title (custom name, else the folder(s)
/// scanned — the memorable identity), then a relative time + outcome ("Clean" when none). A pin marks
/// favorites; a "Rescan" badge flags scans whose folders changed on disk since.
private struct SessionRow: View {
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

/// Persistent header: the primary actions only — Add Folders + Scan. Sits directly under the toolbar
/// in every state and never moves. Folder chips were removed from the header (they dragged focus and
/// competed with the primary actions); the folder set still persists across launches and is scanned.
private struct HomeHeader: View {
    let isScanning: Bool
    let canScan: Bool
    let onAdd: () -> Void
    let onScan: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Add Folders…", systemImage: "plus", action: onAdd)
                .disabled(isScanning)
            Spacer()
            Button("Scan", action: onScan)
                .buttonStyle(.borderedProminent)
                .disabled(isScanning || !canScan)
        }
        .padding(.horizontal).padding(.vertical, 8)
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
                    Text("\(groups.count) group\(groups.count == 1 ? "" : "s") · "
                        + "\(reclaimable.formatted(.byteCount(style: .file))) reclaimable")
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

#Preview {
    RootView().environment(AppEnvironment.preview())
}
