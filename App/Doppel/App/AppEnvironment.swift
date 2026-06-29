import DetectionEngine
import DoppelKit
import Foundation
import IndexStore
import Observation
import OSLog

/// Composition root / DI container (STATE_MANAGEMENT.md §2). Manual constructor injection — no DI framework.
@MainActor
@Observable
final class AppEnvironment {
    let store: any IndexStoring
    let coordinator: any ScanCoordinating
    let embedding: any EmbeddingProvider
    let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "app")

    init(
        store: any IndexStoring,
        coordinator: any ScanCoordinating,
        embedding: any EmbeddingProvider
    ) {
        self.store = store
        self.coordinator = coordinator
        self.embedding = embedding
    }

    /// Live wiring. The GRDB store path lives in Application Support (DATA_MODEL.md §1).
    static func live() -> AppEnvironment {
        let store: any IndexStoring = makeStore()
        return AppEnvironment(store: store, coordinator: ScanCoordinator(), embedding: StubEmbeddingProvider())
    }

    static func preview() -> AppEnvironment {
        AppEnvironment(
            store: InMemoryIndexStore(),
            coordinator: PlaceholderCoordinator(),
            embedding: StubEmbeddingProvider()
        )
    }

    private static func makeStore() -> any IndexStoring {
        do {
            let dir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent(AppInfo.productName, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return try GRDBIndexStore(path: dir.appendingPathComponent("index.sqlite"))
        } catch {
            // Fall back to in-memory so the app still launches; surfaced as a recoverable error in M8.
            return InMemoryIndexStore()
        }
    }
}

/// Temporary no-op coordinator so the app compiles and launches before the real engine (T2.3) lands.
struct PlaceholderCoordinator: ScanCoordinating {
    func scan(_: ScanRequest) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.discovered(total: 0))
            continuation.yield(.finished(summary: ScanSummary()))
            continuation.finish()
        }
    }
}
