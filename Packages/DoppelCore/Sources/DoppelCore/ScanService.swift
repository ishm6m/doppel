import DetectionEngine
import DoppelKit
import Foundation
import IndexStore
import Observation

/// App-layer adapter between the pure engine and the store (API.md §5, STATE_MANAGEMENT.md §5).
/// Owns the scan session lifecycle: creates the session up front (the engine can't — it's pure and
/// has no DB), persists files + groups as `ScanEvent`s stream in, and finalizes the session at the end.
/// Exposes minimal `@Observable` state the ViewModels render. ViewModels never touch the store directly.
@MainActor
@Observable
public final class ScanService {
    private let coordinator: any ScanCoordinating
    private let store: any IndexStoring

    /// Groups found so far in the current scan, in arrival order — UI shows results before completion.
    public private(set) var groups: [DuplicateGroup] = []
    /// Latest progress phase, for the scan header. Nil before the first scan.
    public private(set) var phase: ScanPhase?
    /// Authoritative summary, set when the scan terminates.
    public private(set) var summary: ScanSummary?

    public init(coordinator: any ScanCoordinating, store: any IndexStoring) {
        self.coordinator = coordinator
        self.store = store
    }

    /// Runs a scan to completion, persisting as it goes, and returns the owning sessionID.
    /// `rootBookmarkIDs` ties the session to its security-scoped sources (empty in tests).
    @discardableResult
    public func startScan(_ request: ScanRequest, rootBookmarkIDs: [Int64] = []) async throws -> Int64 {
        let sessionID = try await store.createSession(
            ScanSession(id: 0, rootBookmarkIDs: rootBookmarkIDs, scopes: request.scopes)
        )
        groups = []
        phase = nil
        summary = nil

        var final = ScanSummary()
        var state: ScanState = .finished
        for try await event in coordinator.scan(request) {
            switch event {
            case .discovered:
                break
            case let .progress(phase, _, _):
                self.phase = phase
            case let .groupFound(group, members):
                // ponytail: persist the group's members + the group. We do NOT persist a full file
                // inventory — the engine only emits grouped/skipped files, which is all the results
                // UI needs. Add whole-corpus persistence when a screen actually needs every file.
                try await store.upsertFiles(members)
                _ = try await store.saveGroup(group, members: members.map(\.id), edges: [], sessionID: sessionID)
                // ponytail: edges:[] — groupFound carries no MatchEdges; the compare view (F8) doesn't
                // exist yet. Thread real edges through when it does.
                groups.append(group)
            case .fileSkipped:
                break
            case let .finished(summary):
                final = summary
            case let .cancelled(summary):
                final = summary
                state = .cancelled
            }
        }

        summary = final
        try await store.updateSession(ScanSession(
            id: sessionID,
            finishedAt: .now,
            rootBookmarkIDs: rootBookmarkIDs,
            scopes: request.scopes,
            filesDiscovered: final.filesDiscovered,
            groupsFound: final.groupsFound,
            bytesReclaimable: final.bytesReclaimable,
            state: state
        ))
        return sessionID
    }
}
