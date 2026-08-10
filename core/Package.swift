// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "innerjoin-core",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "InnerjoinCore", targets: ["InnerjoinCore"]),
        .executable(name: "ijparse", targets: ["ijparse"]),
        .executable(name: "ijcheck", targets: ["ijcheck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "InnerjoinCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "ijparse",
            dependencies: [
                "InnerjoinCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // The checks run as a plain executable rather than a test target: swift-testing
        // and XCTest both need a full Xcode install to link, and the preprocessor should
        // be verifiable with Command Line Tools alone. Run with `swift run ijcheck`.
        .executableTarget(
            name: "ijcheck",
            dependencies: ["InnerjoinCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
