import Foundation

/// Serves n-gram instantly on main; LLM runs async off-main.
/// Matches the shape of predictor.py's CompositePredictor.
@MainActor
final class CompositePredictor {
    let ngram: NGramPredictor
    let llm: LLMPredictor?

    init(ngram: NGramPredictor, llm: LLMPredictor?) {
        self.ngram = ngram
        self.llm = llm
    }

    /// Sync n-gram path — safe to call on the event-tap thread.
    func predictFast(word: String, context: [String]) -> (String, PredictionSource) {
        if let guess = ngram.predict(word: word, context: context) {
            return (guess, .ngram)
        }
        return ("", .none)
    }

    /// Fire an async LLM request. `completion` runs on main.
    func requestLLM(word: String, context: [String], completion: @escaping (String?) -> Void) {
        llm?.predictAsync(word: word, context: context, completion: completion)
    }
}
