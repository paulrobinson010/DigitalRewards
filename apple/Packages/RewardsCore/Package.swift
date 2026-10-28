// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RewardsCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "RewardsCore", targets: ["RewardsCore"]),
    ],
    targets: [
        .target(name: "RewardsCore"),
        .testTarget(name: "RewardsCoreTests", dependencies: ["RewardsCore"]),
    ]
)
