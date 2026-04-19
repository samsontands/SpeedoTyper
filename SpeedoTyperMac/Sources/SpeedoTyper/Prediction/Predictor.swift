import Foundation

protocol Predictor: AnyObject {
    /// Return the best completion for `word` given rolling `context`, or nil.
    func predict(word: String, context: [String]) -> String?
}

enum PredictionSource { case ngram, llm, none }
