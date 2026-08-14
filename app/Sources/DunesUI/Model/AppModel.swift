import Foundation
import Observation
import SwiftUI
import DunesCore

/// What the panel is doing. The whole app is this one small state machine, which is what
/// lets a single window morph between asking, answering and browsing without ever opening
/// a second one.
enum Mode: Equatable, Sendable {
    case ask
    case answering
    case browsing(Scope)

    enum Scope: String, Equatable, Sendable, CaseIterable {
        case people, watching, sources, files

        var title: String {
            switch self {
            case .people:   return "People"
            case .watching: return "Tasks"
            case .sources:  return "Sources"
            case .files:    return "Files"
            }
        }

        var symbol: String {
            switch self {
            case .people:   return "person.2"
            case .watching: return "checkmark.circle"
            case .sources:  return "tray.and.arrow.down"
            case .files:    return "square.on.square"
            }
        }

        /// What an empty list should say. Written per-scope because "No results" tells
        /// somebody nothing about what to do next.
        var empty: String {
            switch self {
            case .people:   return "No people yet. They appear as documents are understood."
            case .watching: return "Nothing dated or contradictory in your files."
            case .sources:  return "One workspace, on this Mac."
            case .files:    return "No files yet. Add some with `dunes add ~/Documents`."
            }
        }
    }
}

/// One question and its answer.
struct Turn: Identifiable, Sendable {
    let id = UUID()
    let question: String
    var working: String?
    var text = ""
    var citations: [Library.Citation] = []
    var finished = false
}

@MainActor
@Observable
final class AppModel {
    private(set) var mode: Mode = .ask
    private(set) var snapshot = Library.Snapshot()
    private(set) var turn: Turn?
    private(set) var rows: [Library.Row] = []
    private(set) var loadingRows = false

    /// The agenda, and the two pieces of state that make finishing something feel like
    /// an act rather than a repaint.
    private(set) var tasks: [Commitment] = []
    /// Ticked, still on screen, on its way out. The row draws itself finished while
    /// this holds it, which is what gives the animation something to animate.
    private(set) var settling: Set<String> = []
    /// The last thing finished, and how to put it back.
    private(set) var undoable: Commitment?

    private var undoTimer: Task<Void, Never>?

    var draft = ""

    /// Who this library belongs to, or nil until somebody says. The panel shows the way
    /// in until this is answered — the app has one job and it is personal enough to be
    /// worth naming an owner for.
    private(set) var account: Account?
    private(set) var signIn: SignIn?

    private let library: Library
    private var answerTask: Task<Void, any Error>?

    init(library: Library = Library()) {
        self.library = library
    }

    var isAnswering: Bool {
        if case .answering = mode { return turn?.finished == false }
        return false
    }

    func load() async {
        account = AccountStore.load(from: library.workspace)
        if account == nil { beginSignIn() }
        snapshot = (try? await library.snapshot()) ?? Library.Snapshot()
    }

    var needsSignIn: Bool { account == nil }

    private func beginSignIn() {
        signIn = SignIn(workspace: library.workspace) { [weak self] account in
            guard let self else { return }
            withAnimation(Glass.Motion.morph) {
                self.account = account
                self.signIn = nil
            }
        }
    }

    /// Forget who's signed in. The library itself is untouched — this says nothing about
    /// the documents, only about whose name is on them.
    func signOut() {
        AccountStore.clear(from: library.workspace)
        account = nil
        dismiss()
        beginSignIn()
    }

    // MARK: - Asking

    func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }

        answerTask?.cancel()
        draft = ""
        let current = Turn(question: trimmed)
        turn = current
        mode = .answering

        answerTask = Task { [library] in
            for try await chunk in library.answer(trimmed) {
                // A superseded stream must never write into a newer turn.
                guard turn?.id == current.id else { return }
                switch chunk {
                case .working(let note):  turn?.working = note
                case .text(let body):     turn?.working = nil; turn?.text += body
                case .citation(let one):  turn?.citations.append(one)
                case .done:               turn?.finished = true
                }
            }
        }
    }

    // MARK: - Browsing

    func browse(_ scope: Mode.Scope) {
        guard mode != .browsing(scope) else { return dismiss() }
        answerTask?.cancel()
        mode = .browsing(scope)
        rows = []
        loadingRows = true

        Task { [library] in
            if scope == .watching {
                let fetched = (try? await library.tasks()) ?? []
                guard case .browsing(.watching) = mode else { return }
                tasks = fetched
                // Both are about a click that happened on a list that is no longer on
                // screen. An undo bar that outlives the visit offers to reverse
                // something the person has stopped thinking about, and points at a row
                // this fetch has already dropped.
                settling = []
                undoable = nil
                undoTimer?.cancel()
                loadingRows = false
                return
            }
            let fetched: [Library.Row]
            switch scope {
            case .people:   fetched = (try? await library.people()) ?? []
            case .files:    fetched = (try? await library.files()) ?? []
            case .sources:  fetched = Self.sourceRows(for: library)
            case .watching: fetched = []
            }
            guard case .browsing(scope) = mode else { return }
            rows = fetched
            loadingRows = false
        }
    }

    // MARK: - Finishing things

    /// Tick something off.
    ///
    /// Two stages on purpose. The row is marked settling immediately, so it can draw
    /// itself finished and be *seen* to be finished; only then does it leave. Removing
    /// it on the click would be faster and would feel like the app had swallowed it —
    /// the pause is the acknowledgement.
    ///
    /// The write happens straight away regardless, so a quit mid-animation still keeps
    /// the decision.
    func finish(_ item: Commitment) {
        guard !settling.contains(item.id) else { return }
        settling.insert(item.id)
        undoTimer?.cancel()
        undoable = item

        Task { [library] in
            try? await library.setTaskDone(item.id, done: true)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(420))
            guard settling.contains(item.id) else { return }   // undone in the meantime
            tasks.removeAll { $0.id == item.id }
            settling.remove(item.id)
        }
        undoTimer = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            undoable = nil
        }
    }

    /// Put the last finished thing back, wherever it belongs in the order.
    func undoFinish() {
        guard let item = undoable else { return }
        undoable = nil
        undoTimer?.cancel()
        settling.remove(item.id)

        Task { [library] in
            try? await library.setTaskDone(item.id, done: false)
            guard case .browsing(.watching) = mode else { return }
            // Re-read rather than re-insert: the agenda decides the order, and putting
            // it back by hand would be a second, quietly diverging implementation.
            tasks = (try? await library.tasks()) ?? tasks
        }
    }

    /// Set something aside. It comes back on its own once the date passes.
    func snooze(_ item: Commitment, until: Date) {
        settling.insert(item.id)
        undoTimer?.cancel()
        undoable = nil

        Task { [library] in
            try? await library.snoozeTask(item.id, until: until)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            tasks.removeAll { $0.id == item.id }
            settling.remove(item.id)
        }
    }

    /// Sources is the one list that isn't a table query — it describes where the library
    /// physically is, which is the honest answer to "where does this come from?".
    private static func sourceRows(for library: Library) -> [Library.Row] {
        [
            Library.Row(
                id: "workspace",
                title: library.workspace.lastPathComponent,
                detail: library.workspace.deletingLastPathComponent().path,
                symbol: "internaldrive",
                question: "What kinds of files are in my library?"
            )
        ]
    }

    /// Back to the resting panel. One way out of every mode, bound to Escape.
    ///
    /// The turn and rows deliberately survive: the departing view is still on screen
    /// for its exit fade, and a view emptied mid-fade reads as a glitch, not an exit.
    /// `ask` and `browse` replace them on the way in; the cancel stops a stale stream
    /// from narrating to nobody.
    func dismiss() {
        answerTask?.cancel()
        undoTimer?.cancel()
        undoable = nil
        mode = .ask
    }
}
