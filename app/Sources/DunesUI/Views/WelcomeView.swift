import SwiftUI

/// The way in.
///
/// It is the same panel — same glass, same type, same motion — because this is not a
/// door in front of the app, it is the app's first screen. What it asks for is kept
/// deliberately small: a way to know whose library this is, and then it gets out of the
/// way. Nothing here creates an account on a server, and the screen says so, because a
/// local-first app that opens with a sign-in wall owes the reader that sentence
/// immediately rather than in a privacy policy.
struct WelcomeView: View {
    @Bindable var model: SignIn

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            switch model.step {
            case .welcome:      Doors(model: model)
            case .email:        EmailFlow(model: model)
            case .done:         Color.clear
            }

            Spacer(minLength: 0)

            if let problem = model.problem {
                Problem(text: problem)
                    .transition(Glass.Motion.settle(from: 4))
            }
        }
        .animation(Glass.Motion.arrive, value: model.step)
        .animation(Glass.Motion.arrive, value: model.problem)
    }
}

// MARK: - The three doors

private struct Doors: View {
    @Bindable var model: SignIn

    var body: some View {
        VStack(spacing: Glass.Space.inner) {
            VStack(spacing: 5) {
                Text("Make this library yours")
                    .font(Glass.Font.prompt)
                    .foregroundStyle(Glass.Ink.primary)
                    .arrives(0)
                Text("Your files stay on this Mac. Signing in only says who they belong to.")
                    .font(Glass.Font.footnote)
                    .foregroundStyle(Glass.Ink.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
                    .arrives(1)
            }

            VStack(spacing: Glass.Space.tight) {
                SignInButton(title: "Continue with Apple", symbol: "apple.logo",
                             prominent: true) { model.continueWithApple() }
                    .arrives(2)
                SignInButton(title: "Continue with Google", mark: "G") { model.continueWithGoogle() }
                    .arrives(3)
                SignInButton(title: "Continue with email", symbol: "envelope") { model.beginEmail() }
                    .arrives(4)
            }
            .frame(maxWidth: 300)
            .disabled(model.busy)
            .opacity(model.busy ? 0.5 : 1)
        }
    }
}

// MARK: - Email, one question at a time

private struct EmailFlow: View {
    @Bindable var model: SignIn
    @FocusState private var focused: Bool

    private var stage: SignIn.EmailStage {
        if case .email(let stage) = model.step { return stage }
        return .address
    }

    var body: some View {
        VStack(spacing: Glass.Space.inner) {
            VStack(spacing: 5) {
                Text(title)
                    .font(Glass.Font.prompt)
                    .foregroundStyle(Glass.Ink.primary)
                    .contentTransition(.opacity)
                if let note {
                    Text(note)
                        .font(Glass.Font.footnote)
                        .foregroundStyle(Glass.Ink.tertiary)
                        .contentTransition(.opacity)
                }
            }

            Group {
                if stage == .address {
                    Field(text: $model.address, placeholder: "you@example.com",
                          secure: false, focused: $focused, submit: model.submitAddress)
                } else {
                    Field(text: $model.password,
                          placeholder: stage == .choosePassword ? "At least 8 characters" : "Password",
                          secure: true, focused: $focused, submit: model.submitPassword)
                }
            }
            .frame(maxWidth: 300)

            HStack(spacing: Glass.Space.tight) {
                PanelButton(title: "Back", icon: "chevron.left") { model.back() }
                PanelButton(title: stage == .choosePassword ? "Create" : "Continue",
                            icon: "arrow.right", wide: true) {
                    stage == .address ? model.submitAddress() : model.submitPassword()
                }
            }
            .frame(maxWidth: 300)
        }
        // The field is the only thing on screen worth touching, so it should already be
        // holding the caret — and again when the question changes underneath it.
        .onAppear { focused = true }
        .onChange(of: stage) { _, _ in focused = true }
    }

    private var title: String {
        switch stage {
        case .address:        return "What's your email?"
        case .password:       return "Welcome back"
        case .choosePassword: return "Choose a password"
        }
    }

    private var note: String? {
        switch stage {
        case .address:        return nil
        case .password:       return model.address
        case .choosePassword: return "It unlocks this library on this Mac. There's no account to recover it from."
        }
    }
}

private struct Field: View {
    @Binding var text: String
    let placeholder: String
    let secure: Bool
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(Glass.Font.field)
        .foregroundStyle(Glass.Ink.primary)
        .focused(focused)
        .onSubmit(submit)
        .padding(.horizontal, Glass.Space.inner)
        .frame(height: 38)
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
    }
}

// MARK: - Furniture

private struct SignInButton: View {
    let title: String
    var symbol: String?
    var mark: String?
    var prominent = false
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                } else if let mark {
                    // A letterform rather than the brand's own artwork, which an app
                    // has no licence to redraw from memory.
                    Text(mark)
                        .font(.system(size: 12, weight: .bold, design: .serif))
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Glass.Ink.primary.opacity(0.1)))
                }
                Text(title).font(Glass.Font.control)
            }
            .foregroundStyle(prominent
                             ? (scheme == .dark ? Color.black.opacity(0.85) : .white)
                             : Glass.Ink.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: Glass.Radius.field, style: .continuous)
                        .fill(Glass.Ink.primary.opacity(hovering ? 1 : 0.88))
                } else {
                    RoundedRectangle(cornerRadius: Glass.Radius.field, style: .continuous)
                        .fill(hovering ? Glass.Fill.controlHover(scheme) : Glass.Fill.control(scheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: Glass.Radius.field, style: .continuous)
                                .strokeBorder(Glass.Fill.rim(scheme), lineWidth: 0.5)
                        )
                }
            }
            .scaleEffect(pressed ? 0.98 : 1)
        }
        .buttonStyle(.plain)
        .animation(Glass.Motion.touch, value: hovering)
        .animation(Glass.Motion.touch, value: pressed)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}

private struct Problem: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(Glass.Font.footnote)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Glass.Ink.secondary)
        .frame(maxWidth: 340)
        .padding(.bottom, Glass.Space.tight)
    }
}
