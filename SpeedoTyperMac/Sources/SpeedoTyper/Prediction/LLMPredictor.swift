import Foundation
import Cllama

/// Gemma 4 E2B autocomplete via llama.cpp (same runtime Cotypist uses).
/// Loaded lazily on a background thread; `available` flips true once ready.
final class LLMPredictor: Predictor {
    private let modelPath: String
    private let nCtx: Int32
    private let nGpuLayers: Int32
    private let maxNewTokens: Int32 = 48
    /// Read by finalize() on each call. KeyboardEngine updates this from Config.
    var maxWords: Int = 6

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?

    private let predictLock = NSLock()
    private let queue = DispatchQueue(label: "SpeedoTyper.LLM", qos: .userInitiated)
    private var pendingWork: DispatchWorkItem?
    private(set) var available = false
    private(set) var loadError: String?

    init(modelPath: String, nCtx: Int32 = 2048, nGpuLayers: Int32 = -1) {
        self.modelPath = modelPath
        self.nCtx = nCtx
        self.nGpuLayers = nGpuLayers
        Thread.detachNewThread { [weak self] in self?.loadBackend() }
    }

    deinit {
        if let sampler { llama_sampler_free(sampler) }
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
    }

    // MARK: - Model lifecycle

    private func loadBackend() {
        ggml_backend_load_all()
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
        // Discourage repetition of tokens seen in the last 64 positions.
        // Without this, Gemma at temp<0.2 falls into hard loops on short prompts.
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(
            /* last_n    */ 64,
            /* repeat    */ 1.3,
            /* freq      */ 0.0,
            /* present   */ 0.6
        ))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.5))
        llama_sampler_chain_add(chain, llama_sampler_init_min_p(0.05, 1))
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

    private func buildPrompt(contextText: String, prefix: String) -> String {
        // Bare text continuation — Gemma acts as a next-token predictor.
        // Context is the recent sentence tail; prefix is the in-progress word.
        return contextText + prefix
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
                    /* parse_special */ false
                )
            }
        }
        guard n > 0 else { return nil }
        return Array(out.prefix(Int(n)))
    }

    private func piece(for token: llama_token) -> String? {
        guard let vocab else { return nil }
        var buf = [CChar](repeating: 0, count: 64)
        var n = buf.withUnsafeMutableBufferPointer { b in
            llama_token_to_piece(vocab, token, b.baseAddress, Int32(b.count), 0, /* special */ false)
        }
        if n < 0 {
            let needed = Int(-n)
            buf = [CChar](repeating: 0, count: needed + 1)
            n = buf.withUnsafeMutableBufferPointer { b in
                llama_token_to_piece(vocab, token, b.baseAddress, Int32(b.count), 0, /* special */ false)
            }
        }
        guard n > 0 else { return "" }
        let terminatorIdx = min(Int(n), buf.count - 1)
        buf[terminatorIdx] = 0
        return String(cString: buf)
    }

    // MARK: - Predict

    /// Async wrapper — decode runs on a background queue, completion fires on main.
    /// Cancels any pending (not-yet-started) request so the queue stays shallow.
    func predictAsync(word: String, context: [String], completion: @escaping (String?) -> Void) {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let result = self.predict(word: word, context: context)
            DispatchQueue.main.async { completion(result) }
        }
        pendingWork = work
        queue.async(execute: work)
    }

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
        var firstTok = true
        for _ in 0..<Int(maxNewTokens) {
            let tok = llama_sampler_sample(sampler, ctx, -1)
            if firstTok {
                NSLog("[SpeedoTyper] llm firstTok=%d eog=%d piece='%@'", tok, llama_vocab_is_eog(vocab, tok) ? 1 : 0, piece(for: tok) ?? "(nil)")
                firstTok = false
            }
            if llama_vocab_is_eog(vocab, tok) { break }
            if let p = piece(for: tok) {
                output += p
                if output.count > 24 {
                    let tail = output.suffix(12)
                    let prior = output.dropLast(12).suffix(12)
                    if !tail.isEmpty && tail == prior { break }
                }
                // Stop at sentence boundaries or paragraph breaks.
                if output.contains("\n\n") {
                    if let r = output.range(of: "\n\n") { output = String(output[..<r.lowerBound]) }
                    break
                }
                if p.contains("\n") { break }
            }
            var next = tok
            let stepOk = withUnsafeMutablePointer(to: &next) { ptr -> Bool in
                let batch = llama_batch_get_one(ptr, 1)
                return llama_decode(ctx, batch) == 0
            }
            if !stepOk { break }
        }
        NSLog("[SpeedoTyper] llm raw '%@' → '%@'", word, output)
        return finalize(raw: output, prefix: word)
    }

    // MARK: - Normalize raw continuation → prefix-extended suggestion

    private func finalize(raw: String, prefix: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let startsWithWhitespace = raw.first?.isWhitespace == true

        // Cap continuation at the first newline and strip trailing whitespace.
        var cont = raw
        if let nl = cont.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            cont = String(cont[..<nl])
        }
        // Truncate to max N words if configured (1..N means cap; 0 means no cap).
        if maxWords > 0 {
            cont = truncateToWords(cont, max: maxWords)
        }
        while let last = cont.last, last.isWhitespace { cont.removeLast() }
        guard !cont.isEmpty else { return nil }

        let lowerPrefix = prefix.lowercased()
        let lowerCont = cont.lowercased()

        // Case A: LLM repeats the prefix then keeps going — "th" → "there are cats"
        if lowerCont.hasPrefix(lowerPrefix), lowerCont.count > lowerPrefix.count {
            return matchCase(prefix: prefix, to: cont)
        }
        // Case B: LLM started with whitespace → prefix is done, cont is the rest.
        if startsWithWhitespace {
            let trimmedLead = cont.drop(while: { $0.isWhitespace })
            guard !trimmedLead.isEmpty else { return nil }
            return prefix + " " + String(trimmedLead)
        }
        // Case C: LLM returned just the continuation of the current word/sentence.
        guard let first = cont.first, first.isLowercase || first.isNumber else { return nil }
        let firstWordEnd = cont.firstIndex(where: { $0.isWhitespace }) ?? cont.endIndex
        let firstWord = cont[..<firstWordEnd]
        let combinedWord = prefix + String(firstWord)
        guard combinedWord.count <= 30 else { return nil }
        let rest = cont[firstWordEnd...].drop(while: { $0.isWhitespace })
        let combined = rest.isEmpty ? combinedWord : combinedWord + " " + String(rest)
        return matchCase(prefix: prefix, to: combined)
    }

    /// Keep only the first `max` whitespace-delimited words. Preserves the
    /// original spacing up to the cut so prefix+cont concatenation is clean.
    private func truncateToWords(_ s: String, max: Int) -> String {
        var seen = 0
        var inWord = false
        var endIdx = s.startIndex
        for i in s.indices {
            let ch = s[i]
            if ch.isWhitespace {
                if inWord { inWord = false }
            } else {
                if !inWord {
                    inWord = true
                    seen += 1
                    if seen > max {
                        endIdx = i
                        return String(s[..<endIdx])
                    }
                }
            }
            endIdx = s.index(after: i)
        }
        return s
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
