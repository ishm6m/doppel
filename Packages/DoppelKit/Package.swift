// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoppelKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DoppelKit", targets: ["DoppelKit"])
    ],
    targets: [
        .target(
            name: "DoppelKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DoppelKitTests",
            dependencies: ["DoppelKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
