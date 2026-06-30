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

    private var scanService: ScanService {
        env.scanService
    }

    private var isScanning: Bool {
        scanTask != nil
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
        } detail: {
            InspectorPlaceholder()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result, !urls.isEmpty { startScan(urls) }
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
            ScanProgressView(phase: scanService.phase, groups: scanService.groups, members: scanService.membersByID)
        } else if !scanService.groups.isEmpty {
            ResultsList(groups: scanService.groups, members: scanService.membersByID)
        } else if scanService.summary != nil {
            ContentUnavailableView("No duplicates found 🎉", systemImage: "checkmark.seal")
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

    private func startScan(_ urls: [URL]) {
        scanTask = Task {
            // Sandbox: fileImporter URLs are security-scoped — must open access around the scan.
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                try await scanService.startScan(ScanRequest(roots: urls, scopes: [.document]))
            } catch is CancellationError {
                // Expected when the user hits Cancel; ScanService still finalizes the session.
            } catch {
                scanError = error.localizedDescription
            }
            scanTask = nil
        }
    }
}

enum SidebarItem: Hashable { case sources, scans }

/// Live scan header + groups as they arrive (UI_SPEC.md §5). Indeterminate bar for now —
/// determinate progress needs processed/total counts threaded through ScanService (T4.3 full).
private struct ScanProgressView: View {
    let phase: ScanPhase?
    let groups: [DuplicateGroup]
    let members: [Int64: FileRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProgressView().controlSize(.small)
                Text(phase.map { $0.rawValue.capitalized + "…" } ?? "Scanning…")
                    .font(.headline)
                Spacer()
                Text("\(groups.count) groups").foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            ResultsList(groups: groups, members: members)
        }
        .padding(.top)
    }
}

/// Flat list of expandable GroupCards (UI_SPEC.md §6).
private struct ResultsList: View {
    let groups: [DuplicateGroup]
    let members: [Int64: FileRecord]

    var body: some View {
        List(groups) { group in
            GroupCard(group: group, members: members)
        }
    }
}

private struct GroupCard: View {
    let group: DuplicateGroup
    let members: [Int64: FileRecord]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            // ponytail: rows resolve from the in-memory member map; a file we somehow didn't retain
            // is skipped rather than crashing. Member IDs are unique per scan, so order is stable.
            ForEach(group.memberFileIDs, id: \.self) { id in
                if let file = members[id] {
                    MemberRow(file: file, isKeeper: id == group.keeperFileID)
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

/// One file within a group (UI_SPEC.md §6 member row). The suggested keeper is starred; making the
/// star interactive + selection checkboxes arrive with safe deletion (T5.2).
private struct MemberRow: View {
    let file: FileRecord
    let isKeeper: Bool

    var body: some View {
        HStack(spacing: 8) {
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
