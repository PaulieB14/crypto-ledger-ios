// swift-tools-version:5.9
import PackageDescription

// Runs the number-parsing checks without Xcode, which is deliberate: this repo
// is developed on a machine that has only Command Line Tools, so a test that
// needed a full Xcode test target would never actually be run.
//   cd Tests/LocaleNumbers && swift run
let package = Package(
    name: "LocaleNumbers",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "LocaleNumbers", path: "Sources/LocaleNumbers")]
)
