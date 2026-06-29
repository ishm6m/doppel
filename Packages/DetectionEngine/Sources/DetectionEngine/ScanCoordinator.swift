import DoppelKit
import Foundation

/// Orchestrates Stage 0 (enumerate) + Stage 1 (exact hash) into a cancellable, incrementally-emitting
/// scan (T2.3, ARCHITECTURE.md §3–4). Pure engine: emits `ScanEvent`s only — the app-side ScanService
/// persists them. Incremental re-scan skips files whose signature is in `request.knownSignatures`.
public actor ScanCoordinator: ScanCoordinating {
    /// Test seam: lets a test inject a hash closure (e.g. to trigger cancellation mid-run). Defaults to real.
    private let hash: (@Sendable (URL) throws -> Data)?

    public init() {
        hash = nil
    }

    init(hash: @escaping @Sendable (URL) throws -> Data) {
        self.hash = hash
    }

    public nonisolated func scan(_ request: ScanRequest) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(request, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func run(_ request: ScanRequest, _ c: AsyncThrowingStream<ScanEvent, Error>.Continuation) async {
        var summary = ScanSummary()
        func emitSkips(_ skips: [(FileRecord, FileIssue)]) {
            for (rec, issue) in skips {
                c.yield(.fileSkipped(rec, issue)); summary.skippedCount += 1
            }
        }

        // Stage 0: enumerate (synchronous), then drop unchanged files (incremental) before any hashing.
        let s0 = FileEnumerator(scopes: request.scopes).enumerate(roots: request.roots)
        let candidates = request.knownSignatures.isEmpty
            ? s0.files
            : s0.files.filter { !request.knownSignatures.contains($0.record.signature) }
        summary.filesDiscovered = candidates.count
        c.yield(.discovered(total: candidates.count))
        emitSkips(s0.skipped)

        if Task.isCancelled { c.yield(.cancelled(partial: summary)); c.finish(); return }

        // Stage 1: hash only size buckets with ≥2 members; emit groups as each bucket resolves.
        let buckets = Stage0Result(files: candidates, skipped: []).exactCandidateBuckets()
        let grouper = hash.map { ExactGrouper(maxConcurrency: request.config.maxConcurrency, hash: $0) }
            ?? ExactGrouper(maxConcurrency: request.config.maxConcurrency)
        let totalToHash = buckets.reduce(0) { $0 + $1.count }
        var hashed = 0
        var exactGroups: [ResolvedGroup] = []

        for bucket in buckets {
            if Task.isCancelled { c.yield(.cancelled(partial: summary)); c.finish(); return }
            let r = await grouper.group(bucket: bucket)
            hashed += bucket.count
            c.yield(.progress(phase: .hashing, processed: hashed, total: totalToHash))
            for g in r.groups {
                exactGroups.append(g)
                emitGroup(g, &summary, c)
            }
            emitSkips(r.skipped)
        }

        // Stage 2: near-text on survivors (one representative per exact group + all unmatched docs).
        if Task.isCancelled { c.yield(.cancelled(partial: summary)); c.finish(); return }
        let inputs = await extractText(survivors(of: candidates, exactGroups: exactGroups), &summary, c)
        c.yield(.progress(phase: .fingerprinting, processed: inputs.count, total: inputs.count))
        for g in NearTextStage(config: request.config).group(inputs) {
            emitGroup(g, &summary, c)
        }

        c.yield(.progress(phase: .clustering, processed: totalToHash, total: totalToHash))
        c.yield(.finished(summary: summary))
        c.finish()
    }

    private func emitGroup(_ g: ResolvedGroup, _ summary: inout ScanSummary, _ c: AsyncThrowingStream<ScanEvent, Error>.Continuation) {
        c.yield(.groupFound(g.group, members: g.members))
        summary.groupsFound += 1
        // Reclaimable = every duplicate beyond the one keeper.
        summary.bytesReclaimable += Int64(g.members.count - 1) * (g.members.first?.sizeBytes ?? 0)
    }

    /// Files that carry forward to content stages: every unmatched file, plus one keeper per exact
    /// group (so the group's content can still cross-match *other* files). ARCHITECTURE.md §3.
    private func survivors(of candidates: [EnumeratedFile], exactGroups: [ResolvedGroup]) -> [EnumeratedFile] {
        var memberIDs = Set<Int64>(), keepers = Set<Int64>()
        for g in exactGroups {
            memberIDs.formUnion(g.group.memberFileIDs)
            keepers.insert(g.group.keeperFileID)
        }
        return candidates.filter { !memberIDs.contains($0.record.id) || keepers.contains($0.record.id) }
    }

    private func extractText(
        _ files: [EnumeratedFile],
        _ summary: inout ScanSummary,
        _ c: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async -> [NearTextStage.Input] {
        let extractor = PlainTextExtractor()
        var inputs: [NearTextStage.Input] = []
        for f in files where PlainTextExtractor.handledExtensions.contains(f.url.pathExtension.lowercased()) {
            do {
                if let text = try await extractor.extract(f.url).normalizedText, !text.isEmpty {
                    inputs.append(.init(record: f.record, text: text))
                }
            } catch {
                c.yield(.fileSkipped(f.record, FileIssue(kind: .decodeFailed, message: String(describing: error))))
                summary.skippedCount += 1
            }
        }
        return inputs
    }
}
