import SwiftUI

/// The window's whole content: one glass panel that morphs between asking, answering and
/// browsing. There is never a second window, and never a sheet — the panel *becomes* the
/// thing you asked for and comes back when you're done.
struct Panel: View {
    @Bindable var model: AppModel

    @Environment(\.colorScheme) private var scheme
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model)

            // A ZStack, not a Group: during a handoff the leaver and the arriver are
            // both on screen for a few frames, and they must overlap in place. In a
            // stack they'd lay out side by side and shove each other around — which is
            // exactly the lurch this panel used to have.
            ZStack {
                switch model.mode {
                case .ask:
                    AskView(model: model, focused: $fieldFocused)
                        .transition(Glass.Motion.handoff)
                case .answering:
                    AnswerView(model: model)
                        .transition(Glass.Motion.handoff)
                case .browsing(.watching):
                    TasksView(model: model)
                        .transition(Glass.Motion.handoff)
                case .browsing(let scope):
                    BrowseView(model: model, scope: scope)
                        .transition(Glass.Motion.handoff)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Footer(mode: model.mode)
        }
        .padding(Glass.Space.edge)
        // The single Liquid Glass surface in the app.
        //
        // One, deliberately: glass cannot sample other glass, so a panel of glass holding
        // buttons of glass renders the buttons flat and dead. This samples the desktop
        // behind the window and refracts it; everything inside is drawn with plain
        // translucent fills that read as frosted because of what they sit on.
        .glassEffect(
            .regular.tint(Glass.sand.opacity(scheme == .dark ? 0.05 : 0.08)),
            in: .rect(cornerRadius: Glass.Radius.panel, style: .continuous)
        )
        // A hairline of light along the top edge, the way a real bevel catches it.
        .overlay(
            RoundedRectangle(cornerRadius: Glass.Radius.panel, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(scheme == .dark ? 0.22 : 0.7),
                                 Color.white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: Glass.Radius.panel, style: .continuous))
        // Cast onto the frame behind it rather than onto the desktop — the shadow is
        // now what separates the panel from the glass it sits in, and that separation
        // is most of what reads as depth.
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 12, y: 4)
        .padding(Glass.Space.band)
        .frame(
            width: Glass.restSize.width,
            height: model.mode == .ask ? Glass.restSize.height : Glass.openSize.height
        )
        // Declared shorter than it draws, and pinned to the bottom, so the overflow
        // rises into the title-bar strip. The window then measures exactly the glass.
        .frame(
            width: Glass.restSize.width,
            height: (model.mode == .ask ? Glass.restSize.height : Glass.openSize.height)
                - Glass.titlebarStrip,
            alignment: .bottom
        )
        .animation(Glass.Motion.morph, value: model.mode)
        .onAppear { fieldFocused = true }
        // Escape always returns to the resting panel. One way out of everything.
        .background {
            Button("") { model.dismiss(); fieldFocused = true }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Header

/// The wordmark, and the one control that isn't a scope: Files.
private struct Header: View {
    @Bindable var model: AppModel

    @State private var hoveringMark = false

    var body: some View {
        HStack(alignment: .center) {
            Button {
                model.dismiss()
            } label: {
                Text("dunes")
                    .font(Glass.Font.wordmark)
                    .tracking(-0.4)
                    .foregroundStyle(Glass.Ink.primary)
                    // The wordmark is secretly a way home, and a hover dim is the
                    // whole hint: enough to say "press me", quiet enough to stay a mark.
                    .opacity(hoveringMark ? 0.6 : 1)
            }
            .buttonStyle(.plain)
            .animation(Glass.Motion.touch, value: hoveringMark)
            .onHover { hoveringMark = $0 }
            .accessibilityLabel("dunes — back to the question")

            Spacer()

            // The one control that changes with mode, so it changes the way the panel
            // does: the old label blurs away as the new one forms — a button being
            // relabelled, not a button being replaced. Overlapped in a ZStack so the
            // two labels trade places without the row reflowing.
            ZStack(alignment: .trailing) {
                if case .browsing(let scope) = model.mode, scope != .files {
                    PanelButton(title: scope.title, icon: scope.symbol) { model.dismiss() }
                        .transition(AnyTransition(.blurReplace).animation(Glass.Motion.arrive))
                } else {
                    PanelButton(title: "Files", icon: "square.on.square") {
                        model.browse(.files)
                    }
                    .transition(AnyTransition(.blurReplace).animation(Glass.Motion.arrive))
                }
            }
        }
    }
}

// MARK: - Footer

/// The disclosure. It stays on every screen because the honest caveat about a machine
/// reading your files shouldn't be something you have to go looking for.
private struct Footer: View {
    let mode: Mode

    var body: some View {
        Text(caption)
            .font(Glass.Font.footnote)
            .foregroundStyle(Glass.Ink.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, Glass.Space.snug)
            // The caption crossfades between modes instead of snapping — the smallest
            // text on the panel shouldn't be the only thing that still jump-cuts.
            .contentTransition(.opacity)
            .animation(Glass.Motion.arrive, value: caption)
    }

    private var caption: String {
        switch mode {
        case .ask, .answering:
            return "Answers come from your own files, with sources. Double-check anything important."
        case .browsing:
            return "Everything here is on this Mac. Nothing is uploaded."
        }
    }
}

// MARK: - Ask

/// The resting state: a question, a field, and three ways in.
struct AskView: View {
    @Bindable var model: AppModel
    var focused: FocusState<Bool>.Binding

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: Glass.Space.inner) {
            Spacer(minLength: 0)

            Text(model.snapshot.isEmpty ? "Nothing saved yet" : "What do you want to know?")
                .font(Glass.Font.prompt)
                .foregroundStyle(Glass.Ink.primary)
                .contentTransition(.opacity)
                .animation(Glass.Motion.arrive, value: model.snapshot.isEmpty)
                .arrives(0)

            AskField(model: model, focused: focused)
                .arrives(1)

            HStack(spacing: Glass.Space.snug) {
                ForEach(Array([Mode.Scope.people, .watching, .sources].enumerated()),
                        id: \.element) { index, scope in
                    PanelButton(
                        title: scope.title,
                        // Only Tasks carries a count, and only when something has
                        // actually slipped. A badge on every button is furniture; one
                        // that appears when it means something is a signal.
                        badge: scope == .watching && model.snapshot.overdue > 0
                            ? "\(model.snapshot.overdue)" : nil,
                        wide: true
                    ) { model.browse(scope) }
                        .arrives(2 + index)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

/// The field, and the key that sends it.
private struct AskField: View {
    @Bindable var model: AppModel
    var focused: FocusState<Bool>.Binding

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: Glass.Space.snug) {
            ZStack(alignment: .leading) {
                // The placeholder is drawn by hand rather than passed to the field,
                // because a native placeholder can only sit there — this one hands off
                // to the next prompt while the panel rests.
                if model.draft.isEmpty {
                    PromptCarousel(prompts: model.snapshot.prompts)
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(Glass.Motion.touch))
                }
                TextField("", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Glass.Font.field)
                    .foregroundStyle(Glass.Ink.primary)
                    .lineLimit(1...3)
                    .focused(focused)
                    .onSubmit { model.ask(model.draft) }
                    .accessibilityLabel("Ask about your files")
            }

            SendKey(enabled: !model.draft.trimmingCharacters(in: .whitespaces).isEmpty) {
                model.ask(model.draft)
            }
        }
        .padding(.leading, Glass.Space.inner)
        .padding(.trailing, Glass.Space.tight)
        .padding(.vertical, Glass.Space.tight)
        .background(Glass.Fill.field(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: Glass.Radius.field, style: .continuous)
                .strokeBorder(
                    focused.wrappedValue ? Color.primary.opacity(0.18) : Glass.Fill.rim(scheme),
                    lineWidth: focused.wrappedValue ? 1 : 0.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: Glass.Radius.field, style: .continuous))
        .animation(Glass.Motion.touch, value: focused.wrappedValue)
        .onTapGesture { focused.wrappedValue = true }
    }
}

/// The placeholder rotates through things the library has actually noticed, so the
/// first thing a person sees is evidence it has read their files. Each prompt drifts
/// up and hands off to the next — slow enough to be scenery, alive enough to say the
/// library is full of questions.
private struct PromptCarousel: View {
    let prompts: [String]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()

    private static let period: TimeInterval = 5

    var body: some View {
        Group {
            if prompts.count > 1, !reduceMotion {
                TimelineView(.periodic(from: started, by: Self.period)) { context in
                    let beat = max(0, Int((context.date.timeIntervalSince(started)
                        / Self.period).rounded()))
                    ZStack(alignment: .leading) {
                        Text(prompts[beat % prompts.count])
                            .id(beat % prompts.count)
                            .transition(.asymmetric(
                                insertion: AnyTransition.opacity.combined(with: .offset(y: 7))
                                    .animation(.smooth(duration: 0.45).delay(0.1)),
                                removal: AnyTransition.opacity.combined(with: .offset(y: -7))
                                    .animation(.smooth(duration: 0.35))
                            ))
                    }
                }
            } else {
                Text(prompts.first ?? "Ask across everything…")
            }
        }
        .font(Glass.Font.field)
        .foregroundStyle(Glass.Ink.tertiary)
        .lineLimit(1)
        .animation(Glass.Motion.arrive, value: prompts)
    }
}

/// The circular send key. The one filled, saturated object on the panel — which is what
/// makes it read as *the* action without a single word of instruction.
private struct SendKey: View {
    var enabled: Bool
    var action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var pressed = false
    @State private var wakes = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(scheme == .dark ? Color.black.opacity(0.85) : .white)
                // One small hop the moment the key goes live — the panel saying
                // "ready" without a word. Keyed to a counter so it fires on waking
                // only; a key bouncing as it dies would be saying the wrong thing.
                .symbolEffect(.bounce, options: .speed(1.4), value: wakes)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(
                        enabled
                            ? Color.primary.opacity(hovering ? 1 : 0.85)
                            : Color.primary.opacity(0.22)
                    )
                )
                .scaleEffect(pressed ? 0.9 : (hovering && enabled ? 1.06 : 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(Glass.Motion.touch, value: hovering)
        .animation(Glass.Motion.touch, value: pressed)
        .animation(Glass.Motion.touch, value: enabled)
        .onChange(of: enabled) { _, live in
            if live { wakes += 1 }
        }
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .accessibilityLabel("Ask")
    }
}
