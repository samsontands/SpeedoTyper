import AppKit
import CoreGraphics

enum Injector {
    /// Post a sequence of synthetic key events that types `text` at the current focus.
    /// Uses CGEvent.keyboardSetUnicodeString so we don't have to map chars → keycodes.
    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)

        utf16.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
                down.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
                up.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    /// Delete the last typed character by posting a Backspace.
    static func backspace(_ count: Int = 1) {
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true)?.post(tap: .cgAnnotatedSessionEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
