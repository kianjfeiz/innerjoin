import SwiftUI
import AppKit

/// The rail: search, the destinations, and the person at the bottom. 210pt, parchment,
/// with the active row filled solid green — the one saturated object in the chrome.
struct Sidebar: View {
    let destinations: [Destination]
    @Binding var selection: Destination.Kind
    @Binding var query: String

    @Environment(\.palette) private var palette
    /// One rectangle that *moves* between rows rather than a fill that blinks off in one
    /// row and on in another — the difference between a control and a menu.
    @Namespace private var highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SearchField(query: $query)
                .padding(.bottom, Theme.Space.snug)

            ForEach(Array(destinations.enumerated()), id: \.element.id) { index, destination in
                DestinationRow(
                    destination: destination,
                    selected: selection == destination.kind,
                    highlight: highlight
                ) {
                    guard selection != destination.kind else { return }
                    withAnimation(Theme.Motion.hover) { selection = destination.kind }
                }
                .arrives(index)
            }

            Spacer(minLength: Theme.Space.cosy)

            SettingsRow()
            ProfileRow()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.Space.inner)
        .frame(width: 210)
        .background(palette.sidebar)
        .overlay(alignment: .trailing) { Hairline(horizontal: false, neutral: true) }
    }
}

// MARK: - Search

private struct SearchField: View {
    @Binding var query: String
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.faint)

            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(palette.ink)
                .focused($focused)
                .accessibilityLabel("Search the library")

            if query.isEmpty {
                Text("⌘F")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.dim)
            } else {
                Button {
                    withAnimation(Theme.Motion.direct) { query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(palette.card)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(
                    focused ? palette.accent.opacity(0.45)
                            : (hovering ? palette.hairline : palette.hairline.opacity(0.8)),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .animation(Theme.Motion.direct, value: focused)
        .animation(Theme.Motion.direct, value: hovering)
        .onHover { hovering = $0 }
        .background {
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Row

private struct DestinationRow: View {
    let destination: Destination
    let selected: Bool
    let highlight: Namespace.ID
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: destination.kind.icon)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? palette.heroInk : palette.nav.opacity(0.85))

                Text(destination.kind.title)
                    .font(Theme.Font.nav)
                    .foregroundStyle(selected ? palette.heroInk : palette.nav)

                Spacer(minLength: Theme.Space.tight)

                if let count = destination.count {
                    Text(abbreviated(count))
                        .font(Theme.Font.count)
                        .foregroundStyle(selected ? palette.heroInk.opacity(0.7) : palette.nav.opacity(0.55))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.heroGreen)
                        .matchedGeometryEffect(id: "selection", in: highlight)
                } else if hovering {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(palette.card)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.direct, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Footer

private struct SettingsRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button {} label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(palette.nav.opacity(0.8))
                Text("Settings")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.nav)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(hovering ? palette.card : Color.clear)
            )
            .offset(x: hovering ? 2 : 0)
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.direct, value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct ProfileRow: View {
    @Environment(\.palette) private var palette
    @State private var hovering = false

    /// The account is the person at the keyboard — the app has no login. Their real
    /// name, from the system, and the workspace folder's real name.
    private var fullName: String { NSFullUserName() }
    private var initials: String {
        let parts = fullName.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? ""
        let last = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }
    /// The workspace folder's real name — "Personal", or whatever a harness pointed at.
    private var workspaceName: String {
        LiveBriefingSource.defaultWorkspace.lastPathComponent
    }

    var body: some View {
        HStack(spacing: 9) {
            Text(initials)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(palette.heroInk)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.heroGreen))

            VStack(alignment: .leading, spacing: 1) {
                Text(fullName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(workspaceName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(hovering ? palette.card : Color.clear)
        )
        .animation(Theme.Motion.direct, value: hovering)
        .onHover { hovering = $0 }
    }
}
