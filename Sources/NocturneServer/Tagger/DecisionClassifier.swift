import Foundation

/// One choice question's answer: the option picked, the probability per option, and the
/// vendor's own confidence in the pick.
struct ClassifierChoice: Codable, Sendable, Equatable {
    let choice: String
    let probabilities: [String: Double]
    let confidence: Double
}

/// What the classifier of record returns for one film: a probability per mood (one yes/no
/// question each), two primary-mood passes with the options in different orders (disagreement
/// is the unsure signal), and the raw body for replay.
struct ClassifierAnswer: Sendable, Equatable {
    let provider: String
    let model: String
    /// Probability that the film fits the mood, per slug. A mood the vendor did not answer is absent.
    let probabilities: [String: Double]
    let pass1: ClassifierChoice?
    let pass2: ClassifierChoice?
    let rawJson: String
    let inputTokens: Int

    /// Both passes ran and picked the same primary mood.
    var agree: Bool {
        guard let a = pass1?.choice, let b = pass2?.choice else { return false }
        return a == b
    }

    /// The primary mood when the passes agree; nil otherwise.
    var primary: String? { agree ? pass1?.choice : nil }
}

/// Seam over the vendor client so the pipeline and the tests do not care which vendor answers.
protocol DecisionClassifying: Sendable {
    var provider: String { get }
    func classify(textBlock: String, guide: String?, jellyfinId: String, apiKey: String, context: CallContext) async throws -> ClassifierAnswer
}
