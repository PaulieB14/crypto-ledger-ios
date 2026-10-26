// swift-tools-version:5.9
import PackageDescription

// ABI decoding for the Livepeer / Graph staking reads, runnable without Xcode
// (same reasoning as Tests/LocaleNumbers):
//   cd Tests/StakingABI && swift run
let package = Package(
    name: "StakingABI",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "StakingABI", path: "Sources/StakingABI")]
)
