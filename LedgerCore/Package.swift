// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LedgerCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LedgerCore", targets: ["LedgerCore"])
    ],
    targets: [
        .target(
            name: "LedgerCore",
            resources: [.copy("Resources/fixtures.json")]
        ),
        .testTarget(
            name: "LedgerCoreTests",
            dependencies: ["LedgerCore"]
        )
    ]
)
