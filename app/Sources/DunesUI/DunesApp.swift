import SwiftUI
import AppKit

@main
struct DunesApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("dunes", id: "panel") {
            Panel(model: model)
                .task { await model.load() }
                .onAppear(perform: Harness.configureWindow)
                // The window is a hole in the screen that the glass panel floats in.
                // This is the switch that makes it one: without it the system paints an
                // opaque background behind the content and the glass has nothing to
                // refract but grey.
                //
                // It goes on the *view*, not the scene — `containerBackground(_:for:)` is
                // a View modifier despite reading like window configuration.
                .containerBackground(.clear, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultWindowPlacement { _, context in
            // Slightly above centre, where a person's eye already is.
            let size = context.defaultDisplay.visibleRect.size
            return WindowPlacement(
                CGPoint(x: (size.width - Glass.restSize.width) / 2,
                        y: max(60, size.height * 0.28)),
                size: Glass.restSize
            )
        }
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

/// The harness.
///
/// The app's normal behaviour is entirely real — it opens the same library the CLI
/// writes. What this adds is *addressability*: any state the panel can be in can be put
/// on screen and photographed in one command, because the states worth looking at are
/// the ones nobody reaches by hand.
///
///     ./run.sh                             the real library
///     DUNES_WORKSPACE=/tmp/w ./run.sh      a different library
///     DUNES_APPEARANCE=dark ./run.sh       force an appearance, this process only
///     DUNES_ASK="…" ./run.sh               ask on launch, so the answer path renders
///     DUNES_BROWSE=people ./run.sh         open straight into a list
///     DUNES_SHOT=/path.png ./shot.sh       render, photograph itself, exit
enum Harness {
    static func configureWindow() {
        DispatchQueue.main.async {
            let environment = ProcessInfo.processInfo.environment

            switch environment["DUNES_APPEARANCE"] {
            case "dark":  NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
            default: break
            }

            guard let window = NSApplication.shared.windows.first else { return }
            // The panel draws its own corners and shadow, so the window must contribute
            // neither — otherwise a grey rectangle shows through behind the radius.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }

            if let path = environment["DUNES_SHOT"], path.hasSuffix(".png") {
                window.setFrame(NSRect(x: 120, y: 200,
                                       width: Glass.restSize.width + 20,
                                       height: Glass.restSize.height + 20),
                                display: true)
                window.makeKeyAndOrderFront(nil)
                let delay = Double(environment["DUNES_SHOT_DELAY"] ?? "") ?? 2.4
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    capture(window, to: path)
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    /// The app photographs its own window.
    ///
    /// Works for ordinary drawing and **not** for Liquid Glass: the material is
    /// composited by the window server out of what lies *behind* the window, so a view
    /// that renders itself into a bitmap has nothing to draw and the shot comes back
    /// blank. Photographing this UI needs `screencapture` and the Screen Recording
    /// permission that comes with it — which is the user's to grant, not the app's to
    /// assume. Kept for the opaque states, honest about the glass ones.
    @MainActor
    private static func capture(_ window: NSWindow, to path: String) {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }
}
