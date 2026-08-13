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

            Group {
                switch model.mode {
                case .ask:
                    AskView(model: model, focused: $fieldFocused)
                case .answering:
                    AnswerView(model: model)
                case .browsing(let scope):
                    BrowseView(model: model, scope: scope)
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
        .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.22), radius: 30, y: 14)
        .padding(Glass.Space.snug)
        .frame(
            width: Glass.restSize.width,
            height: model.mode == .ask ? Glass.restSize.height : Glass.openSize.height
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

    var body: some View {
        HStack(alignment: .center) {
            Button {
                model.dismiss()
            } label: {
                Text("dunes")
                    .font(Glass.Font.wordmark)
                    .tracking(-0.4)
                    .foregroundStyle(Glass.Ink.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("dunes — back to the question")

            Spacer()

            if case .browsing(let scope) = model.mode, scope != .files {
                PanelButton(title: scope.title, icon: scope.symbol) { model.dismiss() }
                    .transition(.opacity)
            } else {
                PanelButton(title: "Files", icon: "square.on.square") {
                    model.browse(.files)
                }
            }
        }
        .animation(Glass.Motion.touch, value: model.mode)
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
                .arrives(0)

            AskField(model: model, focused: focused)
                .arrives(1)

            HStack(spacing: Glass.Space.snug) {
                ForEach(Array([Mode.Scope.people, .watching, .sources].enumerated()),
                        id: \.element) { index, scope in
                    PanelButton(title: scope.title, wide: true) { model.browse(scope) }
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
            TextField(placeholder, text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Glass.Font.field)
                .foregroundStyle(Glass.Ink.primary)
                .lineLimit(1...3)
                .focused(focused)
                .onSubmit { model.ask(model.draft) }
                .accessibilityLabel("Ask about your files")

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

    /// The placeholder rotates through things the library has actually noticed, so the
    /// first thing a person sees is evidence it has read their files.
    private var placeholder: String {
        model.snapshot.prompts.first ?? "Ask across everything…"
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

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(scheme == .dark ? Color.black.opacity(0.85) : .white)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(
                        enabled
                            ? Color.primary.opacity(hovering ? 1 : 0.85)
                            : Color.primary.opacity(0.22)
                    )
                )
                .scaleEffect(pressed ? 0.92 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(Glass.Motion.touch, value: hovering)
        .animation(Glass.Motion.touch, value: pressed)
        .animation(Glass.Motion.touch, value: enabled)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .accessibilityLabel("Ask")
    }
}
