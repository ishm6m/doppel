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

        // Stages contribute EDGES to these shared collectors; groups are built once, post-Stage-2.
        // No `.groupFound` is emitted until the clustering pass — groups are final when emitted.
        var edges: [StageEdge] = []
        var records: [Int64: FileRecord] = [:]

        // Stage 1: hash only size buckets with ≥2 members; collect exact edges + hashed records.
        let buckets = Stage0Result(files: candidates, skipped: []).exactCandidateBuckets()
        let grouper = hash.map { ExactGrouper(maxConcurrency: request.config.maxConcurrency, hash: $0) }
            ?? ExactGrouper(maxConcurrency: request.config.maxConcurrency)
        let totalToHash = buckets.reduce(0) { $0 + $1.count }
        var hashed = 0

        for bucket in buckets {
            if Task.isCancelled { c.yield(.cancelled(partial: summary)); c.finish(); return }
            let r = await grouper.group(bucket: bucket)
            hashed += bucket.count
            c.yield(.progress(phase: .hashing, processed: hashed, total: totalToHash))
            edges += r.edges
            for rec in r.records {
                records[rec.id] = rec
            }
            emitSkips(r.skipped)
        }

        // Stage 2: near-text on survivors (one representative per exact set + all unmatched docs).
        if Task.isCancelled { c.yield(.cancelled(partial: summary)); c.finish(); return }
        let inputs = await extractText(survivors(of: candidates, exactEdges: edges), &summary, c)
        c.yield(.progress(phase: .fingerprinting, processed: inputs.count, total: inputs.count))
        let near = NearTextStage(config: request.config).group(inputs)
        edges += near.edges
        for rec in near.records where records[rec.id] == nil {
            records[rec.id] = rec
        } // exact-wins keeps sha256

        // Final clustering: one file → one authoritative group. Emit each, then finish.
        if Task.isCancelled { c.yield(.cancelled(partial: summary)); c.finish(); return }
        c.yield(.progress(phase: .clustering, processed: totalToHash, total: totalToHash))
        for g in FinalClustering.cluster(edges: edges, records: records) {
            emitGroup(g, &summary, c)
        }
        c.yield(.finished(summary: summary))
        c.finish()
    }

    private func emitGroup(_ g: ResolvedGroup, _ summary: inout ScanSummary, _ c: AsyncThrowingStream<ScanEvent, Error>.Continuation) {
        c.yield(.groupFound(g.group, members: g.members))
        summary.groupsFound += 1
        // Reclaimable = every duplicate beyond the one keeper.
        summary.bytesReclaimable += Int64(g.members.count - 1) * (g.members.first?.sizeBytes ?? 0)
    }

    /// Files that carry forward to content stages: every file not in any exact set, plus one
    /// representative per exact set (so its content can still cross-match *other* files, which the
    /// final-clustering pass then merges back). ARCHITECTURE.md §3. Members are byte-identical, so
    /// any representative is interchangeable; we pick the lowest id for determinism.
    private func survivors(of candidates: [EnumeratedFile], exactEdges: [StageEdge]) -> [EnumeratedFile] {
        guard !exactEdges.isEmpty else { return candidates }
        let ids = Array(Set(exactEdges.flatMap { [$0.pair.a, $0.pair.b] })).sorted()
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var uf = UnionFind(count: ids.count)
        for e in exactEdges {
            guard let ia = index[e.pair.a], let ib = index[e.pair.b] else { continue }
            uf.union(ia, ib)
        }
        let representatives = Set(uf.groups().compactMap { comp in comp.map { ids[$0] }.min() })
        let inExact = Set(ids)
        return candidates.filter { !inExact.contains($0.record.id) || representatives.contains($0.record.id) }
    }

    private func extractText(
        _ files: [EnumeratedFile],
        _ summary: inout ScanSummary,
        _ c: AsyncThrowingStream<ScanEvent, Error>.Continuation
    ) async -> [NearTextStage.Input] {
        let plain = PlainTextExtractor()
        let pdf = PDFTextExtractor()
        var inputs: [NearTextStage.Input] = []
        for f in files {
            let ext = f.url.pathExtension.lowercased()
            let extractor: ContentExtractor? = PlainTextExtractor.handledExtensions.contains(ext) ? plain
                : PDFTextExtractor.handledExtensions.contains(ext) ? pdf : nil
            guard let extractor else { continue }
            do {
                let content = try await extractor.extract(f.url)
                if content.needsOCR {
                    // F5: scanned PDF surfaced (never silently dropped) for the opt-in OCR pass. The UI
                    // maps .needsOCR skips into a "Needs OCR (N)" bucket; it doesn't enter near-dup empty.
                    c.yield(.fileSkipped(f.record, FileIssue(kind: .needsOCR, message: "Scanned PDF — no text layer; OCR required")))
                    summary.skippedCount += 1
                } else if let text = content.normalizedText, !text.isEmpty {
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
