// swift-tools-version: 6.2
import PackageDescription

// The app is its own package so the engine stays a library with no opinion about UI.
// It links InnerjoinCore directly — the same Store, Ask and Scrutiny the CLI uses —
// because every card on the home screen is derived from the real library. There is no
// fixture layer: a briefing is a query, not a script.
//
// Built with `./run.sh`, which links the executable and wraps it in a .app bundle.
// Deliberately not an Xcode project — this machine has Command Line Tools only, and
// SwiftUI links fine against the CLT SDK (verified before any of this was written).
let package = Package(
    name: "innerjoin-app",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Innerjoin", targets: ["Innerjoin"]),
    ],
    dependencies: [
        .package(path: "../core"),
    ],
    targets: [
        .executableTarget(
            name: "Innerjoin",
            dependencies: [
                .product(name: "InnerjoinCore", package: "core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
