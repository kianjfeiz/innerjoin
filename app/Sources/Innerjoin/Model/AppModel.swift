import Foundation
import Observation

/// Where a briefing comes from.
///
/// This is the seam between the views and the engine. The real conformer is
/// `LiveBriefingSource`, which derives everything from the library; the others exist so
/// the harness can put rare states — a stalled load, a broken workspace — on screen in
/// one command. The views know only this protocol.
protocol BriefingSource: Sendable {
    func briefing() async throws -> Briefing
    func destinations() async throws -> [Destination]
    /// Answering a question. Streams so the answer can be shown as it forms — the app
    /// should never show a spinner where it could show progress.
    func answer(_ question: String) -> AsyncThrowingStream<AnswerChunk, Error>
}

/// A piece of an answer arriving. Citations come as their own case so they can be
/// rendered as objects rather than parsed back out of prose.
enum AnswerChunk: Sendable {
    /// What the app is doing right now, in words — "reading 4 documents".
    case working(String)
    case text(String)
    case citation(label: String, document: String)
    case done
}

/// One turn in the conversation.
struct Exchange: Identifiable, Sendable {
    let id = UUID()
    let question: String
    var working: String?
    var answer: String
    var citations: [Citation]
    var finished: Bool

    struct Citation: Identifiable, Sendable, Hashable {
        let id = UUID()
        let label: String
        let document: String
    }
}

/// The app's live state. `@Observable` so a view redraws when the part it reads changes,
/// rather than when anything at all changes.
@MainActor
@Observable
final class AppModel {
    enum Phase: Sendable { case loading, ready, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var briefing: Briefing?
    private(set) var destinations: [Destination] = []
    private(set) var exchanges: [Exchange] = []
    private(set) var isAnswering = false

    var selected: Destination.Kind = .home
    var draft: String = ""

    private let source: BriefingSource

    init(source: BriefingSource) {
        self.source = source
    }

    func load() async {
        phase = .loading
        do {
            async let briefing = source.briefing()
            async let destinations = source.destinations()
            self.briefing = try await briefing
            self.destinations = try await destinations
            phase = .ready
        } catch {
            // The rail stays navigable even when the library won't open — an empty
            // sidebar reads as a second failure on top of the real one.
            if destinations.isEmpty {
                destinations = Destination.Kind.allCases.map { Destination(kind: $0, count: nil) }
            }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Runs a card's action. Every action *is* a question composed against the real
    /// record, so a button press does exactly what typing the same words would do —
    /// one mechanism, visible in the transcript afterwards.
    func invoke(_ action: SignalAction) {
        ask(action.question)
    }

    func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }

        draft = ""
        isAnswering = true
        let turn = Exchange(question: trimmed, working: nil, answer: "",
                            citations: [], finished: false)
        exchanges.append(turn)
        let index = exchanges.count - 1

        Task { [source] in
            do {
                for try await chunk in source.answer(trimmed) {
                    guard index < exchanges.count else { return }
                    switch chunk {
                    case .working(let note):
                        exchanges[index].working = note
                    case .text(let fragment):
                        exchanges[index].working = nil
                        exchanges[index].answer += fragment
                    case .citation(let label, let document):
                        exchanges[index].citations.append(
                            Exchange.Citation(label: label, document: document))
                    case .done:
                        exchanges[index].finished = true
                    }
                }
            } catch {
                if index < exchanges.count {
                    exchanges[index].answer = "That didn't work: \(error.localizedDescription)"
                    exchanges[index].finished = true
                }
            }
            isAnswering = false
        }
    }

    /// Clears the conversation and returns to the briefing.
    func clearConversation() {
        exchanges.removeAll()
    }
}
