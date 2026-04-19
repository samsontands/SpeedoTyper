import Foundation

/// Port of predictor.py's NGramPredictor.
/// Unigram/bigram/trigram counts + system dictionary, weighted 30/120/400/0.1.
final class NGramPredictor: Predictor {
    private struct PersistShape: Codable {
        var unigrams: [String: Int]
        var bigrams: [String: [String: Int]]
        var trigrams: [String: [String: Int]]
    }

    private var unigrams: [String: Int] = [:]
    private var bigrams: [String: [String: Int]] = [:]
    private var trigrams: [String: [String: Int]] = [:]

    private let dictionary: [String]
    private let dictionaryWeight: [String: Int]

    private let url: URL
    private let lock = NSLock()
    private var dirty = false

    init(url: URL) {
        self.url = url
        let (dict, weights) = Self.loadSystemDictionary()
        self.dictionary = dict
        self.dictionaryWeight = weights
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PersistShape.self, from: data) else { return }
        unigrams = decoded.unigrams
        bigrams = decoded.bigrams
        trigrams = decoded.trigrams
    }

    func save() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let shape = PersistShape(unigrams: unigrams, bigrams: bigrams, trigrams: trigrams)
        dirty = false
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = url.appendingPathExtension("tmp")
            let data = try JSONEncoder().encode(shape)
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            NSLog("[SpeedoTyper] ngram save failed: \(error)")
        }
    }

    // MARK: - Learning

    func observe(word: String, context: [String]) {
        let lower = word.lowercased()
        guard !lower.isEmpty else { return }
        lock.lock()
        unigrams[lower, default: 0] += 1
        if let last = context.last {
            bigrams[last.lowercased(), default: [:]][lower, default: 0] += 1
        }
        if context.count >= 2 {
            let key = "\(context[context.count - 2].lowercased()) \(context[context.count - 1].lowercased())"
            trigrams[key, default: [:]][lower, default: 0] += 1
        }
        dirty = true
        lock.unlock()
    }

    // MARK: - Predictor

    func predict(word: String, context: [String]) -> String? {
        let prefix = word.lowercased()
        guard !prefix.isEmpty else { return nil }

        var candidates: [String: Double] = [:]

        if context.count >= 2 {
            let key = "\(context[context.count - 2].lowercased()) \(context[context.count - 1].lowercased())"
            if let bucket = trigrams[key] {
                for (w, c) in bucket where w.hasPrefix(prefix) && w != prefix {
                    candidates[w, default: 0] += Double(c) * 400
                }
            }
        }
        if let last = context.last {
            if let bucket = bigrams[last.lowercased()] {
                for (w, c) in bucket where w.hasPrefix(prefix) && w != prefix {
                    candidates[w, default: 0] += Double(c) * 120
                }
            }
        }
        for (w, c) in unigrams where w.hasPrefix(prefix) && w != prefix {
            candidates[w, default: 0] += Double(c) * 30
        }
        for w in dictionary where w.hasPrefix(prefix) && w != prefix {
            let base = Double(dictionaryWeight[w] ?? 0)
            candidates[w, default: 0] += base * 0.1 + 0.2
        }

        guard !candidates.isEmpty else { return nil }
        let best = candidates.max(by: { a, b in
            if a.value != b.value { return a.value < b.value }
            return a.key.count > b.key.count  // prefer shorter suggestion on tie
        })!.key

        return matchCase(of: word, applyingTo: best)
    }

    private func matchCase(of prefix: String, applyingTo word: String) -> String {
        guard let first = prefix.first else { return word }
        if prefix.count > 1 && prefix == prefix.uppercased() {
            return word.uppercased()
        }
        if first.isUppercase {
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return word
    }

    // MARK: - System dictionary

    private static func loadSystemDictionary() -> ([String], [String: Int]) {
        let path = "/usr/share/dict/words"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ([], [:])
        }
        var words: [String] = []
        var weights: [String: Int] = [:]
        for raw in contents.split(separator: "\n") {
            let lower = raw.lowercased()
            guard lower.count >= 3,
                  lower.allSatisfy({ $0.isLetter || $0 == "'" }) else { continue }
            words.append(lower)
            // Shorter common words ranked higher.
            weights[lower] = max(0, 12 - lower.count)
        }
        return (words, weights)
    }
}
