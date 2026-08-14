import Foundation

/// A tiny assertion harness.
///
/// The preprocessor should be verifiable with Command Line Tools alone — both
/// swift-testing and XCTest need a full Xcode install to link — so the checks run as
/// an ordinary executable. Same assertions, no framework.
actor Report {
    static let shared = Report()
    private(set) var passed = 0
    private(set) var skipped = 0
    private(set) var failures: [String] = []

    func pass() { passed += 1 }
    func skip() { skipped += 1 }
    func fail(_ message: String) { failures.append(message) }
}

func expect(
    _ condition: Bool,
    _ description: String,
    file: String = #fileID,
    line: Int = #line
) async {
    if condition {
        await Report.shared.pass()
    } else {
        await Report.shared.fail("\(description)  (\(file):\(line))")
    }
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ description: String,
    file: String = #fileID,
    line: Int = #line
) async {
    if actual == expected {
        await Report.shared.pass()
    } else {
        await Report.shared.fail("\(description) — expected \(expected), got \(actual)  (\(file):\(line))")
    }
}

/// Refusing to answer is a result the resolver is *supposed* to produce, so it gets an
/// expectation of its own — and one that prints what it wrongly matched when it fails.
func expectNil<T>(
    _ actual: T?,
    _ description: String,
    file: String = #fileID,
    line: Int = #line
) async {
    if actual == nil {
        await Report.shared.pass()
    } else {
        await Report.shared.fail("\(description) — expected nothing, got \(actual!)  (\(file):\(line))")
    }
}

func expectNotNil<T>(
    _ actual: T?,
    _ description: String,
    file: String = #fileID,
    line: Int = #line
) async {
    await expect(actual != nil, description, file: file, line: line)
}

/// Runs one named group of checks, catching anything thrown so a single broken
/// check can't take the whole run down.
func check(_ name: String, _ body: () async throws -> Void) async {
    do {
        try await body()
        print("  ✓ \(name)")
    } catch {
        await Report.shared.fail("\(name) threw: \(error)")
        print("  ✗ \(name) — threw \(error)")
    }
}

/// A check that needs something of the machine it runs on.
///
/// Speech recognition is the case that forced this: it needs a real user session, and a
/// headless runner has none, so the check fails there for a reason that has nothing to
/// do with the code. The alternative — leaving it failing in CI — trains everyone to
/// ignore a red tick, which costs more than the check is worth.
///
/// It is a *skip*, printed and counted as one, not a pass. A check quietly turning
/// green on a machine that never ran it is the failure mode this is meant to avoid.
func check(_ name: String, needs capability: String,
           _ body: () async throws -> Void) async {
    guard ProcessInfo.processInfo.environment["DUNES_CHECKS_WITHOUT"]?
        .split(separator: ",").map(String.init).contains(capability) != true else {
        await Report.shared.skip()
        print("  – \(name) — skipped, no \(capability) on this machine")
        return
    }
    await check(name, body)
}

struct CheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Unwraps an optional or throws with a useful message, so checks read linearly.
func require<T>(_ value: T?, _ what: String) throws -> T {
    guard let value else { throw CheckError("expected \(what) to exist") }
    return value
}
