import AppKit
import CoreGraphics

@MainActor
final class KeyboardEngine {
    // Fixed system keys
    private static let kEscape: Int64 = 0x35
    private static let kReturn: Int64 = 0x24
    private static let kDelete: Int64 = 0x33
    private static let kSpace: Int64 = 0x31

    private let predictor: CompositePredictor
    private let overlay: OverlayController
    private let store: ConfigStore
    private var tap: EventTap?

    private var acceptFullCode: Int64 { KeyCodes.code(for: store.config.acceptFullKey) ?? 0x30 }
    private var acceptWordCode: Int64 { KeyCodes.code(for: store.config.acceptWordKey) ?? 0x32 }

    // Word + rolling context tracking
    private var currentWord: String = ""
    private var contextWords: [String] = []
    private let contextLimit = 12

    private var currentSuggestion: String = ""
    private var debounceTimer: Timer?

    // Injector.type posts a single keyDown event with the full unicode string.
    // Our own tap sees it, so gate those events out or they'd clobber state
    // (the injected space would commit+dismiss the ongoing progressive Tab).
    private var pendingInjectedEvents: Int = 0

    private var isAppDisabled: Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return store.config.disabledApps.contains(bid)
    }

    // Emoji shortcode state: triggered by `:`, characters appended, second `:` commits.
    private var emojiBuffer: String = ""
    private var inEmojiMode: Bool = false

    init(predictor: CompositePredictor, overlay: OverlayController, store: ConfigStore) {
        self.predictor = predictor
        self.overlay = overlay
        self.store = store
    }

    func start() {
        let tap = EventTap { [weak self] type, event in
            guard let self = self else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                self.handle(type: type, event: event)
            }
        }
        guard tap.start() else {
            NSLog("[SpeedoTyper] CGEventTap failed — Accessibility permission missing or not granted to this binary.")
            return
        }
        self.tap = tap
    }

    func stop() {
        tap?.stop()
        tap = nil
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if isAppDisabled { return Unmanaged.passUnretained(event) }
        if pendingInjectedEvents > 0 {
            pendingInjectedEvents -= 1
            return Unmanaged.passUnretained(event)
        }
        // Any ⌘/⌃/⌥ combo is an app shortcut, not text — pass through untouched.
        // (Shift and Caps Lock stay handled so regular capitalized typing works.)
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            dismiss()
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Emoji acceptance (accept-full key with emoji preview visible)
        if keyCode == acceptFullCode, inEmojiMode {
            commitEmoji()
            return nil
        }
        // Tab = accept one word at a time. Press Tab again for the next word.
        if keyCode == acceptFullCode, !currentSuggestion.isEmpty {
            acceptWord()
            return nil
        }
        if keyCode == acceptWordCode, !currentSuggestion.isEmpty {
            acceptWord()
            return nil
        }
        // Dismiss
        if keyCode == Self.kEscape {
            dismiss()
            exitEmojiMode()
            return Unmanaged.passUnretained(event)
        }

        // Translate the event to a character string (respects modifiers + layout)
        var length: Int = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        let s = String(utf16CodeUnits: chars, count: length)

        if keyCode == Self.kDelete {
            if inEmojiMode {
                if !emojiBuffer.isEmpty { emojiBuffer.removeLast() } else { exitEmojiMode() }
                refreshEmoji()
                return Unmanaged.passUnretained(event)
            }
            if !currentWord.isEmpty { currentWord.removeLast() } else if !contextWords.isEmpty {
                // crude: pop last context word
                contextWords.removeLast()
            }
            dismiss()
            schedulePredict()
            return Unmanaged.passUnretained(event)
        }

        if keyCode == Self.kReturn {
            commitWord()
            dismiss()
            return Unmanaged.passUnretained(event)
        }

        if s == " " {
            commitWord()
            dismiss()
            return Unmanaged.passUnretained(event)
        }

        // Emoji trigger
        if s == ":" {
            if inEmojiMode {
                // second `:` — commit the best match
                commitEmoji()
                return nil  // swallow the second colon
            }
            inEmojiMode = true
            emojiBuffer = ""
            dismiss()
            refreshEmoji()
            return Unmanaged.passUnretained(event)
        }

        if inEmojiMode {
            if !s.isEmpty, s.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic || $0 == "_" }) {
                emojiBuffer.append(s)
                refreshEmoji()
                return Unmanaged.passUnretained(event)
            } else {
                exitEmojiMode()
            }
        }

        // Printable input
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ !$0.properties.isDefaultIgnorableCodePoint }) {
            currentWord.append(s)
            schedulePredict()
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Emoji

    private func refreshEmoji() {
        let matches = EmojiData.match(prefix: emojiBuffer)
        if matches.isEmpty { dismiss(); return }
        overlay.showEmoji(typed: ":" + emojiBuffer, matches: matches)
    }

    private func commitEmoji() {
        let matches = EmojiData.match(prefix: emojiBuffer)
        guard let first = matches.first else { exitEmojiMode(); return }
        // Delete the `:buffer` the user typed, then type the glyph.
        injectBackspace(emojiBuffer.count + 1)
        inject(first.glyph)
        exitEmojiMode()
    }

    private func exitEmojiMode() {
        inEmojiMode = false
        emojiBuffer = ""
        dismiss()
    }

    // MARK: - Prediction + overlay

    private func schedulePredict() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.runPredict() }
        }
    }

    private func runPredict() {
        guard !currentWord.isEmpty else { dismiss(); return }
        let snapshotWord = currentWord
        let snapshotCtx = contextWords

        // Sync n-gram — instant.
        let (fast, _) = predictor.predictFast(word: snapshotWord, context: snapshotCtx)
        NSLog("[SpeedoTyper] predict word='%@' ctx=%d ngram='%@'", snapshotWord, snapshotCtx.count, fast)
        if !fast.isEmpty {
            currentSuggestion = fast
            overlay.show(suggestion: fast, typed: snapshotWord, allowMouseFallback: store.config.mouseFallback)
        }

        // Async LLM — never blocks the event tap.
        predictor.requestLLM(word: snapshotWord, context: snapshotCtx) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSLog("[SpeedoTyper] llm '%@' → '%@'", snapshotWord, result ?? "(nil)")
                guard let result, !result.isEmpty else { return }
                guard self.currentWord == snapshotWord else { return }  // stale
                self.currentSuggestion = result
                self.overlay.show(suggestion: result, typed: self.currentWord, allowMouseFallback: self.store.config.mouseFallback)
            }
        }
    }

    // MARK: - Acceptance

    /// Accept one word of the current suggestion. Pressing Tab again accepts
    /// the next word; the remainder stays visible as ghost text between presses.
    private func acceptWord() {
        let remaining: Substring = {
            if currentWord.isEmpty { return Substring(currentSuggestion) }
            if currentSuggestion.lowercased().hasPrefix(currentWord.lowercased()) {
                return currentSuggestion.dropFirst(currentWord.count)
            }
            return Substring(currentSuggestion)
        }()
        let trimmed = remaining.drop(while: { $0.isWhitespace })
        guard !trimmed.isEmpty else { dismiss(); return }

        if let space = trimmed.firstIndex(where: { $0.isWhitespace }) {
            let word = String(trimmed[..<space])
            inject(word + " ")
            contextWords.append(word)
            trimContext()
            let rest = trimmed[space...].drop(while: { $0.isWhitespace })
            currentWord = ""
            currentSuggestion = String(rest)
            if currentSuggestion.isEmpty {
                dismiss()
            } else {
                overlay.show(suggestion: currentSuggestion, typed: "", allowMouseFallback: store.config.mouseFallback)
            }
        } else {
            let word = String(trimmed)
            inject(word + " ")
            contextWords.append(word)
            trimContext()
            currentWord = ""
            currentSuggestion = ""
            dismiss()
        }
    }

    private func inject(_ text: String) {
        pendingInjectedEvents += 1  // one keyDown event per type() call
        Injector.type(text)
    }

    private func injectBackspace(_ n: Int) {
        pendingInjectedEvents += n
        Injector.backspace(n)
    }

    private func commitWord() {
        if !currentWord.isEmpty {
            contextWords.append(currentWord)
            trimContext()
            predictor.ngram.observe(word: currentWord, context: contextWords)
            currentWord = ""
        }
    }

    private func dismiss() {
        currentSuggestion = ""
        overlay.hide()
    }

    private func trimContext() {
        if contextWords.count > contextLimit {
            contextWords.removeFirst(contextWords.count - contextLimit)
        }
    }
}
