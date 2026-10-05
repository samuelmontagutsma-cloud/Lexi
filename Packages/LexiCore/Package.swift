// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LexiCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FSRS", targets: ["FSRS"]),
        .library(name: "LexiLogic", targets: ["LexiLogic"]),
    ],
    targets: [
        // Pure Foundation. Builds and tests on Linux CI and on iOS.
        .target(name: "FSRS"),
        .target(name: "LexiLogic", dependencies: ["FSRS"]),
        .testTarget(name: "FSRSTests", dependencies: ["FSRS"], exclude: ["vectors.json"]),
        .testTarget(name: "LexiLogicTests", dependencies: ["LexiLogic"]),
    ]
)
