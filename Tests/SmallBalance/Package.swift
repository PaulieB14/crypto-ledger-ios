// swift-tools-version:6.0
import PackageDescription

// The holdings-list filter, runnable without Xcode (same reason as
// Tests/LocaleNumbers: this repo is developed without a full Xcode install).
//   cd Tests/SmallBalance && swift run
//
// Sources/SmallBalance/SmallBalances.swift is a symlink to App/SmallBalances.swift.
let package = Package(
    name: "SmallBalance",
    // macOS 15 matches what `swift` on the GitHub macOS runner checks
    // availability against. Without a platform, SwiftPM assumes an old OS and
    // rejects Decimal.FormatStyle (`formatted`, `currency(code:)`, `locale`).
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "SmallBalance", path: "Sources/SmallBalance")]
)
