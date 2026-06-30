import Foundation

public enum AppInfo {
    /// Single source of truth for the product name (placeholder; rename here only).
    public static let productName = "Doppel"
    public static let bundleIdentifier = "com.doppel.app"
    /// Marketing version from the app bundle (CFBundleShortVersionString); "—" outside an app bundle
    /// (e.g. unit tests / SwiftPM).
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

public enum Similarity {
    /// Cosine similarity in [-1, 1]. Comparisons happen only within LSH candidate buckets (see ARCHITECTURE.md).
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count, "vectors must share dimension")
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in a.indices {
            let x = Double(a[i]); let y = Double(b[i])
            dot += x * y; na += x * x; nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}

/// Keeper heuristic (DATA_MODEL.md §4): newest mtime, then largest size, then shortest path.
public enum KeeperHeuristic {
    public static func suggestKeeper(from files: [FileRecord]) -> FileRecord? {
        files.max { lhs, rhs in
            if lhs.mtime != rhs.mtime { return lhs.mtime < rhs.mtime }
            if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes < rhs.sizeBytes }
            return lhs.relativePath.count > rhs.relativePath.count
        }
    }
}
