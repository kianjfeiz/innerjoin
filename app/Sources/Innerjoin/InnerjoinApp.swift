import SwiftUI
import AppKit

@main
struct InnerjoinApp: App {
    @State private var model = AppModel(source: Harness.source())

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .providesPalette()
                .task {
                    await model.load()
                    // `IJ_ASK="…"` — ask a question the moment the library is ready, so
                    // the whole answer path (retrieval → model → citations) can be
                    // exercised and photographed without a keyboard.
                    if let question = ProcessInfo.processInfo.environment["IJ_ASK"] {
                        model.ask(question)
                    }
                }
                .onAppear(perform: Harness.configureWindow)
        }
        // No title bar: design D runs its own 44pt strip across the top and the real
        // traffic lights sit inside it.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1_060, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// The harness.
///
/// The app's default behaviour is entirely real: open the same workspace the CLI writes,
/// derive the briefing from it. What the harness adds is *addressability* — any state the
/// app can be in can be put on screen in one command, without clicking, because the rare
/// states (a stalled load, a broken workspace, day one) are where craft shows and exactly
/// what nobody reaches by hand while building.
///
///     ./run.sh                          the real library
///     IJ_WORKSPACE=/tmp/w ./run.sh      a different library (a scratch one, a demo one)
///     IJ_STATE=loading ./run.sh         the skeleton, held forever
///     IJ_STATE=failed ./run.sh          the error path
///     IJ_TODAY=2026-08-10 ./run.sh      a pinned clock, so screenshots compare
enum Harness {
    enum State: String {
        case live, loading, failed
    }

    static var state: State {
        State(rawValue: ProcessInfo.processInfo.environment["IJ_STATE"] ?? "") ?? .live
    }

    static func source() -> BriefingSource {
        switch state {
        case .live:    return LiveBriefingSource(workspace: LiveBriefingSource.defaultWorkspace)
        case .loading: return StalledSource()
        case .failed:  return FailingSource()
        }
    }

    /// Rounds off the window chrome, and positions the window deterministically when a
    /// screenshot is being taken so the captured frame is identical every run.
    ///
    /// `IJ_APPEARANCE=dark|light` forces an appearance *on this process only* — the
    /// harness must never write the user's global appearance setting to photograph the
    /// other theme.
    static func configureWindow() {
        DispatchQueue.main.async {
            let environment = ProcessInfo.processInfo.environment

            switch environment["IJ_APPEARANCE"] {
            case "dark":  NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
            default: break
            }

            guard let window = NSApplication.shared.windows.first else { return }
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true

            // `IJ_SHOT=/path.png` — the app photographs itself and exits. In-process
            // rendering rather than `screencapture`, for two reasons: it needs no
            // Screen Recording permission, and it captures the window's own bitmap, so
            // the image is identical whatever else is on the screen.
            if let path = environment["IJ_SHOT"], path.hasSuffix(".png") {
                window.setFrame(NSRect(x: 80, y: 120, width: 1_060, height: 720), display: true)
                window.makeKeyAndOrderFront(nil)
                // Long enough for the load and the arrival stagger to finish; a shot
                // mid-animation photographs cards in flight. `IJ_SHOT_DELAY` stretches
                // it when the shot has to wait for a model round trip.
                let delay = Double(environment["IJ_SHOT_DELAY"] ?? "") ?? 2.2
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    Self.capture(window, to: path)
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    @MainActor
    private static func capture(_ window: NSWindow, to path: String) {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Harness sources

/// Never returns, so the loading state can be looked at for as long as it takes.
private struct StalledSource: BriefingSource {
    func briefing() async throws -> Briefing {
        try await Task.sleep(for: .seconds(3_600))
        throw CancellationError()
    }
    func destinations() async throws -> [Destination] {
        Destination.Kind.allCases.map { Destination(kind: $0, count: nil) }
    }
    func answer(_ question: String) -> AsyncThrowingStream<AnswerChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// The failure path, on demand.
private struct FailingSource: BriefingSource {
    struct Unreachable: LocalizedError {
        var errorDescription: String? {
            "The workspace at ~/Library/Application Support/innerjoin couldn't be opened. "
            + "It may be on a disk that isn't mounted."
        }
    }
    func briefing() async throws -> Briefing { throw Unreachable() }
    func destinations() async throws -> [Destination] {
        Destination.Kind.allCases.map { Destination(kind: $0, count: nil) }
    }
    func answer(_ question: String) -> AsyncThrowingStream<AnswerChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: Unreachable()) }
    }
}
