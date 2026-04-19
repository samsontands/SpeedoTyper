import AppKit
import CoreGraphics

@MainActor
final class KeyboardEngine {
    // Key codes
    private static let kTab: Int64 = 0x30
    private static let kBacktick: Int64 = 0x32
    private static let kEscape: Int64 = 0x35
    private static let kReturn: Int64 = 0x24
    private static let kDelete: Int64 = 0x33
    private static let kSpace: Int64 = 0x31

    private let predictor: CompositePredictor
    private let overlay: OverlayController
    private var tap: EventTap?

    // Word + rolling context tracking
    private var currentWord: String = ""
    private var contextWords: [String] = []
    private let contextLimit = 12

    private var currentSuggestion: String = ""
    private var debounceTimer: Timer?

    init(predictor: CompositePredictor, overlay: OverlayController) {
        self.predictor = predictor
        self.overlay = overlay
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
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Accept full suggestion
        if keyCode == Self.kTab, !currentSuggestion.isEmpty {
            acceptFull()
            return nil  // swallow the Tab
        }
        // Accept next word only
        if keyCode == Self.kBacktick, !currentSuggestion.isEmpty {
            acceptWord()
            return nil
        }
        // Dismiss
        if keyCode == Self.kEscape {
            dismiss()
            return Unmanaged.passUnretained(event)
        }

        // Translate the event to a character string (respects modifiers + layout)
        var length: Int = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        let s = String(utf16CodeUnits: chars, count: length)

        if keyCode == Self.kDelete {
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

        // Printable input
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ !$0.properties.isDefaultIgnorableCodePoint }) {
            currentWord.append(s)
            schedulePredict()
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Prediction + overlay

    private func schedulePredict() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.runPredict() }
        }
    }

    private func runPredict() {
        guard !currentWord.isEmpty else { dismiss(); return }
        let (suggestion, source) = predictor.predict(word: currentWord, context: contextWords)
        _ = source
        guard !suggestion.isEmpty else { dismiss(); return }
        currentSuggestion = suggestion
        overlay.show(typed: currentWord, suggestion: suggestion)
    }

    // MARK: - Acceptance

    private func acceptFull() {
        let remaining = String(currentSuggestion.dropFirst(currentWord.count))
        Injector.type(remaining + " ")
        contextWords.append(currentSuggestion)
        trimContext()
        currentWord = ""
        dismiss()
    }

    private func acceptWord() {
        let remaining = String(currentSuggestion.dropFirst(currentWord.count))
        guard let firstSpace = remaining.firstIndex(where: { $0 == " " }) else {
            Injector.type(remaining + " ")
            contextWords.append(currentSuggestion)
            trimContext()
            currentWord = ""
            dismiss()
            return
        }
        let wordPart = remaining[..<firstSpace]
        Injector.type(String(wordPart) + " ")
        contextWords.append(currentWord + wordPart)
        trimContext()
        currentWord = ""
        dismiss()
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
