// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "dunes-core",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DunesCore", targets: ["DunesCore"]),
        .executable(name: "dunes", targets: ["dunes"]),
        .executable(name: "dunescheck", targets: ["dunescheck"]),
        .executable(name: "duneseval", targets: ["duneseval"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "DunesCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "dunes",
            dependencies: [
                "DunesCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Scores the pipeline against a corpus whose truth is known, at several
        // levels of simulated model error. Run with `swift run duneseval`.
        .executableTarget(
            name: "duneseval",
            dependencies: ["DunesCore"]
        ),
        // The checks run as a plain executable rather than a test target: swift-testing
        // and XCTest both need a full Xcode install to link, and the preprocessor should
        // be verifiable with Command Line Tools alone. Run with `swift run dunescheck`.
        .executableTarget(
            name: "dunescheck",
            dependencies: ["DunesCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
