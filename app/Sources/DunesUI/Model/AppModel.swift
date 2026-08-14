import Foundation
import Observation

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

    var draft = ""

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
        snapshot = (try? await library.snapshot()) ?? Library.Snapshot()
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
            let fetched: [Library.Row]
            switch scope {
            case .people:   fetched = (try? await library.people()) ?? []
            case .watching: fetched = (try? await library.watching()) ?? []
            case .files:    fetched = (try? await library.files()) ?? []
            case .sources:  fetched = Self.sourceRows(for: library)
            }
            guard case .browsing(scope) = mode else { return }
            rows = fetched
            loadingRows = false
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
        mode = .ask
    }
}
