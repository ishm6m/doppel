import Foundation
import UniformTypeIdentifiers
import DoppelKit

// MARK: - Stage 0: Enumeration & signature (T2.1, ARCHITECTURE.md §3)

/// A qualifying file plus the (resolved) URL Stage 1 needs to open it. `record.id` is a scan-local
/// counter; the app layer remaps to DB ids on persist (the engine is pure — no IndexStore).
public struct EnumeratedFile: Sendable {
    public let record: FileRecord
    public let url: URL
}

public struct Stage0Result: Sendable {
    public let files: [EnumeratedFile]
    public let skipped: [(FileRecord, FileIssue)]

    /// Size buckets with ≥2 members — the ONLY input Stage 1 ever sees. A file alone in its size
    /// bucket can't be a *byte* duplicate, so it is never hashed (the core perf invariant).
    public func exactCandidateBuckets() -> [[EnumeratedFile]] {
        Dictionary(grouping: files, by: { $0.record.sizeBytes }).values.filter { $0.count > 1 }.map { $0 }
    }
}

public struct FileEnumerator: Sendable {
    public let scopes: Set<FileTypeScope>
    public let skipsHiddenFiles: Bool
    public let ignoredNames: Set<String>

    // ponytail: ignoredNames is a fixed default until the Settings ignore-list lands; pass-through for now.
    public init(scopes: Set<FileTypeScope>,
                skipsHiddenFiles: Bool = true,
                ignoredNames: Set<String> = [".git", "node_modules", ".DS_Store"]) {
        self.scopes = scopes
        self.skipsHiddenFiles = skipsHiddenFiles
        self.ignoredNames = ignoredNames
    }

    public func enumerate(roots: [URL]) -> Stage0Result {
        let fm = FileManager.default
        var files: [EnumeratedFile] = []
        var skipped: [(FileRecord, FileIssue)] = []
        var visited = Set<String>()   // resolved real paths — guards symlink cycles & double-counting
        var nextID: Int64 = 1

        var options: FileManager.DirectoryEnumerationOptions = []
        if skipsHiddenFiles { options.insert(.skipsHiddenFiles) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]

        for (rootIndex, root) in roots.enumerated() {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                         options: options,
                                         errorHandler: { _, _ in true }) else { continue }
            while let obj = en.nextObject() {
                guard let url = obj as? URL else { continue }

                if ignoredNames.contains(url.lastPathComponent) {
                    en.skipDescendants()   // no-op for plain files
                    continue
                }
                let rv = try? url.resourceValues(forKeys: keys)
                if rv?.isDirectory == true { continue }

                let resolved = url.resolvingSymlinksInPath()
                guard visited.insert(resolved.path).inserted else { continue }

                let fileScope = Self.classify(url)
                guard scopes.contains(fileScope) else { continue }

                let relPath = Self.relativePath(of: url, under: root)
                do {
                    let attrs = try fm.attributesOfItem(atPath: resolved.path)
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
                    let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
                    let rec = FileRecord(id: nextID, bookmarkID: Int64(rootIndex), relativePath: relPath,
                                         displayName: url.lastPathComponent, sizeBytes: size, mtime: mtime,
                                         fileID: inode, typeScope: fileScope)
                    files.append(EnumeratedFile(record: rec, url: resolved))
                } catch {
                    let rec = FileRecord(id: nextID, bookmarkID: Int64(rootIndex), relativePath: relPath,
                                         displayName: url.lastPathComponent, sizeBytes: 0, mtime: .distantPast,
                                         typeScope: fileScope, status: .skipped)
                    skipped.append((rec, FileIssue(kind: .permissionDenied, message: String(describing: error))))
                }
                nextID += 1
            }
        }
        return Stage0Result(files: files, skipped: skipped)
    }

    private static func classify(_ url: URL) -> FileTypeScope {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) || type.conforms(to: .text) { return .document }
        let officeExts: Set<String> = ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "rtf", "pages"]
        return officeExts.contains(url.pathExtension.lowercased()) ? .document : .other
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let p = url.path, base = root.path
        guard p.hasPrefix(base) else { return url.lastPathComponent }
        return String(p.dropFirst(base.count).drop(while: { $0 == "/" }))
    }
}

// MARK: - Stage 1: Exact hash (T2.2, ARCHITECTURE.md §3)

public struct ResolvedGroup: Sendable {
    public let group: DuplicateGroup
    public let members: [FileRecord]   // sha256 attached; ordered by id
}

public struct ExactGrouper: Sendable {
    public let maxConcurrency: Int
    private let hash: @Sendable (URL) throws -> Data

    public init(maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                hash: @escaping @Sendable (URL) throws -> Data = { try Hasher256.hash(fileAt: $0) }) {
        self.maxConcurrency = maxConcurrency
        self.hash = hash
    }

    public func group(_ buckets: [[EnumeratedFile]]) async -> (groups: [ResolvedGroup], skipped: [(FileRecord, FileIssue)]) {
        var groups: [ResolvedGroup] = []
        var skipped: [(FileRecord, FileIssue)] = []
        for bucket in buckets {
            let r = await group(bucket: bucket)
            groups += r.groups
            skipped += r.skipped
        }
        return (groups, skipped)
    }

    /// Hash + cluster a single size bucket. The coordinator iterates buckets itself so it can emit
    /// groups incrementally and honour cancellation between buckets.
    public func group(bucket: [EnumeratedFile]) async -> (groups: [ResolvedGroup], skipped: [(FileRecord, FileIssue)]) {
        var groups: [ResolvedGroup] = []
        var skipped: [(FileRecord, FileIssue)] = []

        var hashed: [(file: EnumeratedFile, digest: Data)] = []
        for (file, outcome) in await hashBucket(bucket) {
            switch outcome {
            case .ok(let digest): hashed.append((file, digest))
            case .fail(let message): skipped.append((file.record, FileIssue(kind: .unreadable, message: message)))
            }
        }

        // Cluster equal-hash files with the shared UnionFind (one group per identical-content set).
        var uf = UnionFind(count: hashed.count)
        var firstForDigest: [Data: Int] = [:]
        for (i, entry) in hashed.enumerated() {
            if let j = firstForDigest[entry.digest] { uf.union(i, j) } else { firstForDigest[entry.digest] = i }
        }
        for cluster in uf.groups() where cluster.count > 1 {
            let members = cluster.map { idx -> FileRecord in
                var r = hashed[idx].file.record
                r.sha256 = hashed[idx].digest
                return r
            }.sorted { $0.id < $1.id }
            guard let keeper = KeeperHeuristic.suggestKeeper(from: members) else { continue }
            let g = DuplicateGroup(id: 0, matchType: .exact, confidence: 1.0,
                                   explanation: "Identical file contents",
                                   keeperFileID: keeper.id, memberFileIDs: members.map(\.id))
            groups.append(ResolvedGroup(group: g, members: members))
        }
        return (groups, skipped)
    }

    private enum HashOutcome: Sendable { case ok(Data); case fail(String) }

    /// Hashes every file in a bucket with a bounded TaskGroup (≤ maxConcurrency in flight at once).
    private func hashBucket(_ bucket: [EnumeratedFile]) async -> [(EnumeratedFile, HashOutcome)] {
        let hash = self.hash
        let cap = max(1, maxConcurrency)
        return await withTaskGroup(of: (Int, HashOutcome).self) { group in
            var results = [HashOutcome?](repeating: nil, count: bucket.count)
            var next = 0
            func submit(_ i: Int) {
                let url = bucket[i].url
                group.addTask {
                    do { return (i, .ok(try hash(url))) } catch { return (i, .fail(String(describing: error))) }
                }
            }
            while next < min(cap, bucket.count) { submit(next); next += 1 }
            while let (i, outcome) = await group.next() {
                results[i] = outcome
                if next < bucket.count { submit(next); next += 1 }
            }
            return bucket.indices.map { (bucket[$0], results[$0] ?? .fail("no result")) }
        }
    }
}
