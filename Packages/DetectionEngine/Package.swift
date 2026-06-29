// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DetectionEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DetectionEngine", targets: ["DetectionEngine"])
    ],
    dependencies: [
        .package(path: "../DoppelKit")
    ],
    targets: [
        .target(
            name: "DetectionEngine",
            dependencies: ["DoppelKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DetectionEngineTests",
            dependencies: ["DetectionEngine", "DoppelKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
