// swift-tools-version:5.9
import PackageDescription

// Once-per-version review prompt policy, runnable without Xcode.
//   cd Tests/ReviewPrompt && swift run
//
// Sources/ReviewPrompt/ReviewPrompt.swift is a symlink to App/ReviewPrompt.swift.
let package = Package(
    name: "ReviewPrompt",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "ReviewPrompt", path: "Sources/ReviewPrompt")]
)
