// swift-tools-version: 6.0
// Target ownership: see docs/kickoff/07-engineering-plan.md "Repo layout". Only T01 edits this file.
import PackageDescription

let benches = ["bench-wer", "bench-llm", "bench-match", "bench-latency", "bench-soak", "bench-report", "bench-label"]

let package = Package(
    name: "Hamsa",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HamsaKit", targets: ["HamsaKit"]),
        .executable(name: "hamsa-cli", targets: ["hamsa-cli"]),
    ] + benches.map { .executable(name: $0, targets: [$0]) },
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "HamsaKit"),
        .target(name: "HamsaBench", dependencies: ["HamsaKit"]),
        .executableTarget(
            name: "hamsa-cli",
            dependencies: ["HamsaKit", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "HamsaKitTests", dependencies: ["HamsaKit"]),
    ] + benches.map {
        .executableTarget(
            name: $0,
            dependencies: ["HamsaKit", "HamsaBench", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        )
    }
)
