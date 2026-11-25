// swift-tools-version:5.9
import PackageDescription

// The holdings-list filter, runnable without Xcode (same reason as
// Tests/LocaleNumbers: this repo is developed without a full Xcode install).
//   cd Tests/SmallBalance && swift run
//
// Sources/SmallBalance/SmallBalances.swift is a symlink to App/SmallBalances.swift.
let package = Package(
    name: "SmallBalance",
    targets: [.executableTarget(name: "SmallBalance", path: "Sources/SmallBalance")]
)
