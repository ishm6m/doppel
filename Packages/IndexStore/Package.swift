// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IndexStore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IndexStore", targets: ["IndexStore"])
    ],
    dependencies: [
        .package(path: "../DoppelKit"),
        // GRDB is the SQLite layer (see DATA_MODEL.md). Pinned to the current stable 7.x (Swift 6 line).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")
    ],
    targets: [
        .target(
            name: "IndexStore",
            dependencies: [
                "DoppelKit",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IndexStoreTests",
            dependencies: ["IndexStore", "DoppelKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
