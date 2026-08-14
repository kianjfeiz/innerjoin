import SwiftUI
import DunesCore

/// What your files are waiting on you for.
///
/// The list is not typed by anyone. Every row was read out of a document, which changes
/// what the screen owes you: a task app has to be trusted to remember what you told it,
/// and this has to be trusted to have *read correctly*. So every row carries where it
/// came from, an inferred date says so, and tapping a row asks about it rather than
/// opening an editor. The one thing you can tell it is that you're done.
struct TasksView: View {
    @Bindable var model: AppModel

    /// Fixed for the life of the view. The horizon a row falls in is computed against
    /// this, and a clock that moved mid-session would reshuffle the list under the
    /// pointer for no reason a person could see.
    @State private var now = Date()

    private var groups: [(horizon: Commitment.Horizon, items: [Commitment])] {
        let buckets = Dictionary(grouping: model.tasks) { $0.horizon(now: now) }
        return buckets.keys.sorted().map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        ZStack {
            if model.loadingRows {
                Color.clear
            } else if model.tasks.isEmpty {
                Settled()
                    .transition(Glass.Motion.settle(after: 0.05, from: 4))
            } else {
                ScrollOrStack {
                    VStack(alignment: .leading, spacing: Glass.Space.tight) {
                        ForEach(Array(groups.enumerated()), id: \.element.horizon) { index, group in
                            Section {
                                ForEach(group.items) { item in
                                    TaskRow(
                                        item: item,
                                        now: now,
                                        settling: model.settling.contains(item.id),
                                        finish: { model.finish(item) },
                                        ask: { model.ask(question(for: item)) },
                                        snooze: { model.snooze(item, until: $0) }
                                    )
                                    // Collapsing upward as it leaves is what makes the
                                    // rows below close the gap rather than jump into it.
                                    .transition(.asymmetric(
                                        insertion: .opacity,
                                        removal: .scale(scale: 0.96, anchor: .leading)
                                            .combined(with: .opacity)))
                                }
                            } header: {
                                GroupHeader(horizon: group.horizon, count: group.items.count)
                                    .arrives(min(index, 4))
                            }
                        }
                    }
                    .padding(.top, Glass.Space.tight)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Glass.Motion.settleRow, value: model.tasks)
        .animation(Glass.Motion.arrive, value: model.loadingRows)
        .safeAreaInset(edge: .bottom, spacing: Glass.Space.tight) {
            if let undoable = model.undoable {
                UndoBar(title: undoable.title) { model.undoFinish() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Glass.Motion.arrive, value: model.undoable?.id)
        // ⌘Z, because finishing something is an edit and this is the one place the app
        // makes one. Bound here rather than globally so it can't fire from the ask
        // field, where it belongs to the text.
        .background {
            Button("") { model.undoFinish() }
                .keyboardShortcut("z", modifiers: .command)
                .opacity(0)
                .disabled(model.undoable == nil)
                .accessibilityHidden(true)
        }
    }

    /// Tapping a row asks about it — the app's one mechanism, kept. The question is
    /// phrased around what the row actually is, so the answer lands on the point.
    private func question(for item: Commitment) -> String {
        switch item.kind {
        case .check:   return "What doesn't add up in \(item.documentLabel)?"
        case .meeting: return "What is \(item.title), and who is involved?"
        case .payment: return "What is owed on \(item.title), and to whom?"
        default:       return "What happens with \(item.title), and when?"
        }
    }
}

// MARK: - A row

private struct TaskRow: View {
    let item: Commitment
    let now: Date
    let settling: Bool
    let finish: () -> Void
    let ask: () -> Void
    let snooze: (Date) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var overdue: Bool { item.horizon(now: now) == .overdue }

    var body: some View {
        HStack(alignment: .top, spacing: Glass.Space.snug) {
            Checkbox(checked: settling, action: finish)
                .padding(.top, 1)

            Button(action: ask) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(Glass.Font.control)
                        .foregroundStyle(Glass.Ink.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        // A contradiction is a whole sentence; without this it is
                        // measured at its ideal width, stays on one line, and gets
                        // cut off at the very point that says what's wrong.
                        .fixedSize(horizontal: false, vertical: true)
                        // Struck through only while it's leaving. A permanent strike
                        // would be decoration; here it is the app agreeing with you.
                        .strikethrough(settling, color: Glass.Ink.tertiary)

                    HStack(spacing: 5) {
                        Image(systemName: item.kind.symbol)
                            .font(.system(size: 8.5, weight: .semibold))
                        Text(item.kind.label)
                        if let when = relativeDue {
                            Dot()
                            Text(when).monospacedDigit()
                        }
                        if item.derived {
                            Dot()
                            // dunes counted this back from another date. Saying so is
                            // the difference between a date you can act on and one you
                            // have to go and check.
                            Text("worked out")
                        }
                        if let source {
                            Dot()
                            Text(source).lineLimit(1)
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(overdue && !settling ? Glass.Ink.secondary : Glass.Ink.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Glass.Ink.faint)
                .opacity(hovering && !settling ? 1 : 0)
                .offset(x: hovering ? 0 : -3)
                .padding(.top, 3)
        }
        .padding(.horizontal, Glass.Space.snug)
        .padding(.vertical, 8)
        .background(hovering ? Glass.Fill.controlHover(scheme) : Glass.Fill.control(scheme))
        .overlay(alignment: .leading) {
            // Overdue earns a mark, not a colour. A red row in a list read at a glance
            // is an alarm; a bar at the edge is a fact you can take or leave.
            if overdue {
                Capsule()
                    .fill(Glass.Ink.primary.opacity(settling ? 0 : 0.35))
                    .frame(width: 2.5)
                    .padding(.vertical, 7)
                    .padding(.leading, 3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Glass.Radius.control, style: .continuous)
                .strokeBorder(Glass.Fill.rim(scheme), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Glass.Radius.control, style: .continuous))
        .opacity(settling ? (reduceMotion ? 1 : 0.45) : 1)
        .animation(Glass.Motion.touch, value: hovering)
        .animation(Glass.Motion.arrive, value: settling)
        .onHover { hovering = $0 }
        // Not everything on the list is yours to finish — some of it is just early.
        // Setting it aside is the honest third option next to done and ignored, and it
        // lapses on its own, so nothing is ever silently lost.
        .contextMenu {
            Button("Ask about this", action: ask)
            Divider()
            Button("Set aside until tomorrow") { snooze(shift(days: 1)) }
            Button("Set aside for a week") { snooze(shift(days: 7)) }
            Button("Set aside for a month") { snooze(shift(days: 30)) }
            Divider()
            Button("Mark done", action: finish)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.kind.label): \(item.title)")
        .accessibilityHint("Ask about this")
        .accessibilityAddTraits(settling ? [.isSelected] : [])
    }

    /// Where it came from, when that adds anything.
    ///
    /// Filenames arrive as "2026-07-21 Meridian Analytics Q2 Usage Report.md": a date
    /// that is already in the row, an extension nobody needs, and a name that is
    /// usually the title again. Repeating the title in smaller grey type is the kind
    /// of detail that makes a row look busy while telling you nothing, so this strips
    /// the packaging and stays quiet when what's left is what you already read.
    private var source: String? {
        var label = item.documentLabel
        for suffix in [".md", ".pdf", ".txt", ".docx", ".eml", ".png", ".jpg"]
        where label.lowercased().hasSuffix(suffix) {
            label = String(label.dropLast(suffix.count))
        }
        // A leading ISO date, which every row already carries in its own words.
        if label.count > 11, label.prefix(4).allSatisfy(\.isNumber), label.dropFirst(4).hasPrefix("-") {
            let rest = label.dropFirst(10)
            if rest.hasPrefix(" ") { label = String(rest.dropFirst()) }
        }
        label = label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        let title = item.title.lowercased()
        let simplified = label.lowercased()
        guard !title.contains(simplified), !simplified.contains(title) else { return nil }
        return label
    }

    /// Start of the day N days out, so "tomorrow" means tomorrow morning rather than
    /// this time tomorrow — a snooze set at 11pm should not lapse at 11pm.
    private func shift(days: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: days, to: now) ?? now
        return calendar.startOfDay(for: day)
    }

    /// How far off it is, in the words a person would use. "In 3 days" is read at a
    /// glance; a date has to be worked out against today first.
    private var relativeDue: String? {
        guard let due = item.due else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: due)
        guard let days = calendar.dateComponents([.day], from: today, to: day).day else { return nil }
        switch days {
        case 0:            return "today"
        case 1:            return "tomorrow"
        case -1:           return "yesterday"
        case 2...6:        return "in \(days) days"
        case -6 ... -2:    return "\(-days) days ago"
        default:           return Library.shortDate(due)
        }
    }
}

private struct Dot: View {
    var body: some View {
        Text("·").foregroundStyle(Glass.Ink.faint)
    }
}

// MARK: - The checkbox

/// The one control in the app that changes the library.
///
/// It is deliberately the only thing on the row with a hit target of its own, and it
/// is deliberately slow enough to see: the ring closes, the fill lands, the tick draws.
/// A checkbox that completes instantly is indistinguishable from one that misfired.
private struct Checkbox: View {
    let checked: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(
                        checked ? Color.clear
                            : Glass.Ink.primary.opacity(hovering ? 0.55 : 0.3),
                        lineWidth: 1.5
                    )
                Circle()
                    .fill(Glass.Ink.primary.opacity(checked ? 0.9 : 0))
                    .scaleEffect(checked ? 1 : 0.1)
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(scheme == .dark ? Color.black.opacity(0.85) : .white)
                    .opacity(checked ? 1 : 0)
                    .scaleEffect(checked ? 1 : 0.4)
            }
            .frame(width: 17, height: 17)
            .scaleEffect(pressed ? 0.86 : (hovering && !checked ? 1.12 : 1))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? Glass.Motion.touch : Glass.Motion.tick, value: checked)
        .animation(Glass.Motion.touch, value: hovering)
        .animation(Glass.Motion.touch, value: pressed)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .accessibilityLabel(checked ? "Done" : "Mark done")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Furniture

private struct GroupHeader: View {
    let horizon: Commitment.Horizon
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(horizon.title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
            Text("\(count)")
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Glass.Ink.faint)
            Spacer(minLength: 0)
        }
        // Overdue is the one heading worth reading twice, so it gets weight rather than
        // the same grey as the rest with a different word in it.
        .foregroundStyle(horizon == .overdue
                         ? Glass.Ink.primary.opacity(0.75) : Glass.Ink.faint)
        .padding(.horizontal, Glass.Space.tight)
        .padding(.top, Glass.Space.tight)
        .padding(.bottom, 2)
    }
}

/// What an empty list should say. Not "no results" — the honest reading of an empty
/// agenda is that there is nothing to do, which is worth saying out loud.
private struct Settled: View {
    var body: some View {
        VStack(spacing: Glass.Space.tight) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Glass.Ink.faint)
            Text("Nothing is waiting on you.")
                .font(Glass.Font.body)
                .foregroundStyle(Glass.Ink.secondary)
            Text("Dates and loose ends appear here as your files are understood.")
                .font(Glass.Font.footnote)
                .foregroundStyle(Glass.Ink.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Spacer()
        }
    }
}

/// A way back, for six seconds.
///
/// Undo is what lets the check-off be quick. Without it the animation has to be a
/// confirmation dialog instead, and the list stops being something you can run down.
private struct UndoBar: View {
    let title: String
    let undo: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Glass.Space.tight) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Glass.Ink.secondary)
            Text(title)
                .font(Glass.Font.footnote)
                .foregroundStyle(Glass.Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: Glass.Space.tight)
            Button(action: undo) {
                Text("Undo")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Glass.Ink.primary)
                    .underline(hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .padding(.horizontal, Glass.Space.snug)
        .frame(height: 28)
        .background(Glass.Fill.control(scheme))
        .overlay(
            Capsule().strokeBorder(Glass.Fill.rim(scheme), lineWidth: 0.5)
        )
        .clipShape(Capsule())
    }
}
