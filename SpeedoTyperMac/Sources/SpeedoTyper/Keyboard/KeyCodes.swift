import Foundation

/// macOS virtual key codes (kVK_*) for the names we expose in Config.
/// Matches the pynput-style names used in the Python version.
enum KeyCodes {
    static let nameToCode: [String: Int64] = [
        "tab": 0x30,
        "`": 0x32,
        "backtick": 0x32,
        "grave": 0x32,
        "esc": 0x35,
        "escape": 0x35,
        "return": 0x24,
        "enter": 0x24,
        "space": 0x31,
        "delete": 0x33,
        "backspace": 0x33,
        // Letters
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
        "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
        "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
        "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06,
    ]

    /// Parse a config string like "tab" or "`" into a virtual key code.
    static func code(for name: String) -> Int64? {
        nameToCode[name.lowercased()]
    }
}
