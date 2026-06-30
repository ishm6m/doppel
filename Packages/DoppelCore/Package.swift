// swift-tools-version: 6.0
import PackageDescription

// DoppelCore: app-layer orchestration (ScanService) over the engine + store. Kept a package, not
// App-target code, so it's unit-testable without an Xcode test host — and shareable with a future
// CLI target (see docs/API.md "Future Improvements"). No SwiftUI; @Observable comes from Observation.
let package = Package(
    name: "DoppelCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DoppelCore", targets: ["DoppelCore"])
    ],
    dependencies: [
        .package(path: "../DoppelKit"),
        .package(path: "../IndexStore"),
        .package(path: "../DetectionEngine")
    ],
    targets: [
        .target(
            name: "DoppelCore",
            dependencies: ["DoppelKit", "IndexStore", "DetectionEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DoppelCoreTests",
            dependencies: ["DoppelCore", "DoppelKit", "IndexStore", "DetectionEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
