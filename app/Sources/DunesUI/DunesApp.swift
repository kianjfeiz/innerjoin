import SwiftUI
import AppKit

@main
struct DunesApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("dunes", id: "panel") {
            Panel(model: model)
                .task {
                    await model.load()
                    await Harness.applyLaunchState(to: model)
                    await Harness.renderIfAsked(model)
                }
                .onAppear(perform: Harness.configureWindow)
                // The window is a hole in the screen that the glass panel floats in.
                // This is the switch that makes it one: without it the system paints an
                // opaque background behind the content and the glass has nothing to
                // refract but grey.
                //
                // It goes on the *view*, not the scene — `containerBackground(_:for:)` is
                // a View modifier despite reading like window configuration.
                .containerBackground(.clear, for: .window)
                // The frame the panel sits in is drawn by Panel itself, so that it is
                // sized by the glass rather than by the window — see WindowGlass.
                //
                // And the window is exactly that glass: no margin, no reserved slack.
                // Its height is written by WindowHeight, frame by frame through a morph.
        }
        .windowStyle(.hiddenTitleBar)
        // Not `.contentSize`: that measures the content's settled layout and resizes
        // the window in one step, which is precisely what WindowHeight exists to
        // interpolate. The panel fills the window and the window is set by hand.
        .windowResizability(.automatic)
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
///     DUNES_AFTER=5 ./run.sh               hold the launch state back, so a camera
///                                          outside the process can catch the morph
///     DUNES_SHOT=/path.png ./shot.sh       render, photograph itself, exit
///     DUNES_RENDER=/path.png ./run.sh      draw straight to a file and quit, with no
///                                          window — works on a locked Mac and over
///                                          ssh, at the cost of flat glass
enum Harness {
    /// Draw the panel straight to a file and quit, with no window involved.
    ///
    /// `DUNES_SHOT` photographs the real window, which is the truthful picture and the
    /// one that needs a screen: Liquid Glass is composited by the window server, so it
    /// simply isn't there in an offscreen pass. This is the other half — `ImageRenderer`
    /// rasterises the view tree itself, so it works over ssh, on a locked Mac, and in
    /// CI. The glass comes out flat, and everything the glass is *holding* — rows,
    /// spacing, type, state — comes out exactly as laid out, which is most of what
    /// there is to get wrong.
    @MainActor
    static func renderIfAsked(_ model: AppModel) async {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["DUNES_RENDER"] else { return }
        // Long enough for the library read the launch state kicked off to land.
        try? await Task.sleep(for: .milliseconds(900))

        // DUNES_SETTLE ticks the first task off and draws the moment afterwards — the
        // half-second a person actually sees when they finish something, which is the
        // state most worth looking at and the one hardest to catch by hand. It goes
        // through the real `finish`, so the picture is of the shipping path and not of
        // a pose arranged for the camera.
        if environment["DUNES_SETTLE"] != nil, let first = model.tasks.first {
            model.finish(first)
        }
        FileHandle.standardError.write(Data(
            "render: mode=\(model.mode) tasks=\(model.tasks.count) loading=\(model.loadingRows)\n".utf8))
        let height = model.needsSignIn ? Glass.welcomeSize.height
            : (model.mode == .ask ? Glass.restSize.height : Glass.openSize.height)
        let renderer = ImageRenderer(content:
            Panel(model: model)
                .frame(width: Glass.restSize.width, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme,
                             environment["DUNES_APPEARANCE"] == "light" ? .light : .dark)
                .environment(\.offscreenRender, true)
        )
        renderer.scale = 2
        defer { NSApplication.shared.terminate(nil) }

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("render produced nothing\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// The launch states the header comment promises. Run after `load()`, so a
    /// harness-driven question or list starts from the same loaded library a person's
    /// would. `DUNES_AFTER` holds the state back by that many seconds — the pause is
    /// what makes a transition photographable, since a camera outside the process
    /// needs to know when the morph will happen.
    @MainActor
    static func applyLaunchState(to model: AppModel) async {
        let environment = ProcessInfo.processInfo.environment
        if let delay = Double(environment["DUNES_AFTER"] ?? ""), delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
        if let step = environment["DUNES_SIGNIN"] {
            model.signIn?.harnessJump(to: step)
        }
        if let question = environment["DUNES_ASK"], !question.isEmpty {
            model.ask(question)
        } else if let raw = environment["DUNES_BROWSE"], let scope = Mode.Scope(rawValue: raw) {
            model.browse(scope)
        }
        // DUNES_RETURN comes back to the resting panel that many seconds later. The
        // shape a panel is left in *after* a morph is a different thing from the shape
        // it launches in, and the bugs that live there — a stale shadow, a frame that
        // didn't shrink with it — are invisible to a camera pointed at a fresh launch.
        if let back = Double(environment["DUNES_RETURN"] ?? ""), back > 0 {
            try? await Task.sleep(for: .seconds(back))
            model.dismiss()
        }
    }

    static func configureWindow() {
        DispatchQueue.main.async {
            let environment = ProcessInfo.processInfo.environment

            switch environment["DUNES_APPEARANCE"] {
            case "dark":  NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
            default: break
            }

            // A panel you summon should be ready to type into the moment it exists —
            // launching without focus would mean clicking before asking.
            NSApplication.shared.activate(ignoringOtherApps: true)

            guard let window = NSApplication.shared.windows.first else { return }
            // Without this the hidden title bar adds its own height to the window, and
            // that surplus is the strip the frame cannot cover evenly.
            window.styleMask.insert(.fullSizeContentView)
            // The panel has one width and four heights, all of them chosen. A window a
            // person can drag to any size would have neither.
            window.styleMask.remove(.resizable)
            window.makeKeyAndOrderFront(nil)
            // The panel draws its own corners, so the window must not paint a
            // background — otherwise a grey rectangle shows through behind the radius.
            window.isOpaque = false
            window.backgroundColor = .clear
            // No shadow, from anywhere.
            //
            // A window shadow is drawn *outside* the window, so it is the one part of
            // the app a person can see and cannot touch: a soft dark ring that looks
            // like it belongs to the panel, sitting on the desktop, passing every click
            // straight through to whatever is behind. On a small floating panel with a
            // glass edge of its own, it read as a third container — an outer one, made
            // of nothing.
            //
            // Without it the app ends at its own edge and every visible pixel is live.
            // The depth that mattered is still there and is drawn *inside*: the panel
            // casts onto the band of glass around it, which is a shadow that is part of
            // the app rather than a halo around it.
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
