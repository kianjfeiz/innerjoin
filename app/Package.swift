// swift-tools-version: 6.2
import PackageDescription

// The app is its own package so the engine stays a library with no opinion about UI.
// It links DunesCore directly — the same Store, Ask and Scrutiny the CLI uses —
// because every card on the home screen is derived from the real library. There is no
// fixture layer: a briefing is a query, not a script.
//
// Built with `./run.sh`, which links the executable and wraps it in a .app bundle.
// Deliberately not an Xcode project — this machine has Command Line Tools only, and
// SwiftUI links fine against the CLT SDK (verified before any of this was written).
// The app target is `DunesUI`, not `Dunes`, and the executable is `dunes-app`.
//
// Both names dodge a case collision: the CLI target in ../core is `dunes`, and on a
// case-insensitive filesystem `Dunes.build/` and `dunes.build/` are one directory. When
// they were, SwiftPM wrote the CLI's output-file-map over the app's, the app's object
// files were emitted under the CLI's names, and the linker failed on seven missing .o
// files while every compile job reported success.
let package = Package(
    name: "dunes-app",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "dunes-app", targets: ["DunesUI"]),
    ],
    dependencies: [
        .package(path: "../core"),
    ],
    targets: [
        .executableTarget(
            name: "DunesUI",
            dependencies: [
                .product(name: "DunesCore", package: "core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
