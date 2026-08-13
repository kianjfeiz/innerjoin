import Foundation

/// What the model calls cost, counted as they happen.
///
/// Two reasons this exists rather than being left to the provider's dashboard. Tuning a
/// prompt means running a corpus over and over, and a prompt that gains a point of
/// accuracy by tripling the tokens is usually a bad trade you can't see without this.
/// And in the app, someone spending their own money on their own key deserves to be told
/// what a run cost rather than finding out at the end of the month.
public actor Meter {
    public static let shared = Meter()

    public private(set) var calls = 0
    public private(set) var inputTokens = 0
    public private(set) var outputTokens = 0
    /// Calls where the service didn't report usage, so the totals are a floor.
    public private(set) var unreported = 0

    public init() {}

    func record(input: Int?, output: Int?) {
        calls += 1
        guard let input, let output else { unreported += 1; return }
        inputTokens += input
        outputTokens += output
    }

    public func reset() {
        calls = 0; inputTokens = 0; outputTokens = 0; unreported = 0
    }

    public struct Snapshot: Sendable {
        public let calls: Int
        public let inputTokens: Int
        public let outputTokens: Int
        public let unreported: Int
        /// Nil unless prices are known — a made-up number here would be worse than none.
        public let dollars: Double?

        public var description: String {
            var text = "\(calls) call\(calls == 1 ? "" : "s") · "
                + "\(inputTokens.formatted()) in / \(outputTokens.formatted()) out"
            if let dollars {
                text += String(format: " · $%.4f", dollars)
            }
            if unreported > 0 { text += " · \(unreported) without usage reported" }
            return text
        }
    }

    public func snapshot(pricing: Pricing? = .fromEnvironment()) -> Snapshot {
        Snapshot(calls: calls, inputTokens: inputTokens, outputTokens: outputTokens,
                 unreported: unreported,
                 dollars: pricing.map {
                     Double(inputTokens) / 1_000_000 * $0.inputPerMillion
                         + Double(outputTokens) / 1_000_000 * $0.outputPerMillion
                 })
    }

    /// Dollars per million tokens, as the service publishes them.
    public struct Pricing: Sendable {
        public let inputPerMillion: Double
        public let outputPerMillion: Double

        public init(inputPerMillion: Double, outputPerMillion: Double) {
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
        }

        /// From `DUNES_PRICE_IN` / `DUNES_PRICE_OUT`. Absent means no dollar figure is shown —
        /// prices change, and a stale hardcoded table would quietly lie.
        public static func fromEnvironment(
            _ environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Pricing? {
            guard let input = environment["DUNES_PRICE_IN"].flatMap(Double.init),
                  let output = environment["DUNES_PRICE_OUT"].flatMap(Double.init)
            else { return nil }
            return Pricing(inputPerMillion: input, outputPerMillion: output)
        }
    }
}
