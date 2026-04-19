import Foundation
import Cllama

/// Gemma 4 E2B autocomplete via llama.cpp (same runtime Cotypist uses).
/// Loaded lazily on a background thread; `available` flips true once ready.
final class LLMPredictor: Predictor {
    private let modelPath: String
    private let nCtx: Int32
    private let nGpuLayers: Int32
    private let customInstructions: String
    private let maxNewTokens: Int32 = 8

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?

    private let predictLock = NSLock()
    private(set) var available = false
    private(set) var loadError: String?

    private static let systemPrompt =
        "You are an autocomplete engine. Given the user's in-progress " +
        "sentence, continue it with the next few words the user is most " +
        "likely to type. Match their register exactly. Reply with only " +
        "the continuation text — no quotes, no explanation, no punctuation " +
        "at the end."

    init(modelPath: String, nCtx: Int32 = 2048, nGpuLayers: Int32 = -1, customInstructions: String = "") {
        self.modelPath = modelPath
        self.nCtx = nCtx
        self.nGpuLayers = nGpuLayers
        self.customInstructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        Thread.detachNewThread { [weak self] in self?.loadBackend() }
    }

    deinit {
        if let sampler { llama_sampler_free(sampler) }
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
    }

    // MARK: - Model lifecycle

    private func loadBackend() {
        llama_backend_init()

        var mp = llama_model_default_params()
        mp.n_gpu_layers = nGpuLayers
        mp.use_mmap = true

        guard let m = llama_model_load_from_file(modelPath, mp) else {
            loadError = "failed to load model at \(modelPath)"
            return
        }
        self.model = m

        guard let v = llama_model_get_vocab(m) else {
            loadError = "model has no vocab"
            return
        }
        self.vocab = v

        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(nCtx)
        cp.n_batch = 512

        guard let c = llama_init_from_model(m, cp) else {
            loadError = "failed to init context"
            return
        }
        self.ctx = c

        let sp = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sp) else {
            loadError = "failed to init sampler"
            return
        }
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.15))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(42))
        self.sampler = chain

        self.available = true
        NSLog("[SpeedoTyper] LLM ready: \(modelPath)")
    }

    func status() -> String {
        if available { return "LLM ready" }
        if let err = loadError { return "LLM unavailable (\(err))" }
        return "LLM loading…"
    }

    // MARK: - Prompt construction

    private func systemText() -> String {
        if customInstructions.isEmpty { return Self.systemPrompt }
        return Self.systemPrompt + "\n\nStyle guide:\n" + customInstructions
    }

    /// Gemma 4 chat template, applied by hand to avoid C-string round-trips.
    private func buildPrompt(contextText: String, prefix: String) -> String {
        let user = contextText.isEmpty ? prefix : "\(contextText)\(prefix)"
        return """
        <start_of_turn>user
        \(systemText())

        \(user)<end_of_turn>
        <start_of_turn>model

        """
    }

    // MARK: - Tokenization helpers

    private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token]? {
        guard let vocab else { return nil }
        let cstr = Array(text.utf8)
        let maxTokens = Int32(cstr.count + 8)
        var out = [llama_token](repeating: 0, count: Int(maxTokens))
        let n = out.withUnsafeMutableBufferPointer { buf -> Int32 in
            cstr.withUnsafeBufferPointer { cbuf in
                llama_tokenize(
                    vocab,
                    cbuf.baseAddress.map { UnsafePointer($0).withMemoryRebound(to: CChar.self, capacity: cbuf.count) { $0 } },
                    Int32(cbuf.count),
                    buf.baseAddress,
                    maxTokens,
                    addSpecial,
                    /* parse_special */ true
                )
            }
        }
        guard n > 0 else { return nil }
        return Array(out.prefix(Int(n)))
    }

    private func piece(for token: llama_token) -> String? {
        guard let vocab else { return nil }
        var buf = [CChar](repeating: 0, count: 64)
        let n = buf.withUnsafeMutableBufferPointer { b in
            llama_token_to_piece(vocab, token, b.baseAddress, Int32(b.count), 0, /* special */ false)
        }
        guard n > 0 else { return "" }
        buf[Int(n)] = 0
        return String(cString: buf)
    }

    // MARK: - Predict

    func predict(word: String, context: [String]) -> String? {
        guard available, !word.isEmpty, let ctx, let vocab, let sampler else { return nil }
        predictLock.lock()
        defer { predictLock.unlock() }

        let ctxText: String = {
            let tail = context.suffix(20).joined(separator: " ")
            return tail.isEmpty ? "" : tail + " "
        }()

        let prompt = buildPrompt(contextText: ctxText, prefix: word)
        guard let tokens = tokenize(prompt, addSpecial: false), !tokens.isEmpty else { return nil }

        // Fresh KV state per call — simple + correct. Optimization: reuse shared prefix.
        if let mem = llama_get_memory(ctx) {
            llama_memory_clear(mem, true)
        }

        // Prompt prefill.
        var tokArr = tokens
        let ok = tokArr.withUnsafeMutableBufferPointer { buf -> Bool in
            let batch = llama_batch_get_one(buf.baseAddress, Int32(buf.count))
            return llama_decode(ctx, batch) == 0
        }
        guard ok else { return nil }

        // Generate up to maxNewTokens.
        var output = ""
        for _ in 0..<Int(maxNewTokens) {
            let tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            if let p = piece(for: tok) {
                output += p
                if p.contains("\n") { break }
            }
            var next = tok
            let stepOk = withUnsafeMutablePointer(to: &next) { ptr -> Bool in
                let batch = llama_batch_get_one(ptr, 1)
                return llama_decode(ctx, batch) == 0
            }
            if !stepOk { break }
        }
        return finalize(raw: output, prefix: word)
    }

    // MARK: - Normalize raw continuation → prefix-extended word

    private static let wordRegex = try! NSRegularExpression(pattern: "[A-Za-z']+")

    private func finalize(raw: String, prefix: String) -> String? {
        let trimmed = raw.drop(while: { $0.isWhitespace })
        guard !trimmed.isEmpty else { return nil }
        let nsString = String(trimmed) as NSString
        guard let match = Self.wordRegex.firstMatch(
            in: String(trimmed),
            range: NSRange(location: 0, length: nsString.length)
        ) else { return nil }
        let firstWord = nsString.substring(with: match.range).lowercased()
        let lowerPrefix = prefix.lowercased()
        if firstWord == lowerPrefix { return nil }

        let result: String
        if firstWord.hasPrefix(lowerPrefix) {
            result = firstWord
        } else {
            let combined = (lowerPrefix + firstWord)
            if combined.hasPrefix(lowerPrefix), combined.count > lowerPrefix.count {
                result = combined
            } else {
                return nil
            }
        }

        return matchCase(prefix: prefix, to: result)
    }

    private func matchCase(prefix: String, to word: String) -> String {
        guard let first = prefix.first else { return word }
        if prefix.count > 1 && prefix == prefix.uppercased() {
            return word.uppercased()
        }
        if first.isUppercase {
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return word
    }
}
