import Foundation

/// Serves n-gram instantly; defers to LLM when one is wired up.
/// Matches the shape of predictor.py's CompositePredictor.
@MainActor
final class CompositePredictor {
    let ngram: NGramPredictor
    private let llm: (any Predictor)?

    init(ngram: NGramPredictor, llm: (any Predictor)?) {
        self.ngram = ngram
        self.llm = llm
    }

    /// Synchronous fast path. Returns (suggestion, source).
    func predict(word: String, context: [String]) -> (String, PredictionSource) {
        if let llm, let guess = llm.predict(word: word, context: context) {
            return (guess, .llm)
        }
        if let guess = ngram.predict(word: word, context: context) {
            return (guess, .ngram)
        }
        return ("", .none)
    }
}
