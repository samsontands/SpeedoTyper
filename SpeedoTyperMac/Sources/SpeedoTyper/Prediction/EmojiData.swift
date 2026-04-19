import Foundation

/// Shortcode → glyph. Matches emoji_data.py 1:1.
enum EmojiData {
    static let table: [(String, String)] = [
        ("smile", "🙂"), ("grin", "😀"), ("joy", "😂"), ("laugh", "😆"), ("wink", "😉"),
        ("love", "❤️"), ("heart", "❤️"), ("heart_eyes", "😍"), ("kiss", "😘"), ("blush", "😊"),
        ("cool", "😎"), ("sunglasses", "😎"), ("thinking", "🤔"), ("neutral", "😐"),
        ("sad", "🙁"), ("cry", "😢"), ("sob", "😭"), ("angry", "😠"), ("rage", "😡"),
        ("shocked", "😱"), ("surprised", "😮"), ("tired", "😫"), ("sleepy", "😴"), ("sick", "😷"),
        ("thumbsup", "👍"), ("thumbs_up", "👍"), ("thumbsdown", "👎"), ("ok", "👌"),
        ("wave", "👋"), ("clap", "👏"), ("pray", "🙏"), ("muscle", "💪"),
        ("point_up", "☝️"), ("point_right", "👉"), ("point_left", "👈"),
        ("fire", "🔥"), ("100", "💯"), ("star", "⭐"), ("sparkles", "✨"),
        ("sun", "☀️"), ("moon", "🌙"), ("rainbow", "🌈"), ("snowflake", "❄️"),
        ("cloud", "☁️"), ("zap", "⚡"), ("bolt", "⚡"), ("rocket", "🚀"),
        ("airplane", "✈️"), ("car", "🚗"), ("bike", "🚲"),
        ("house", "🏠"), ("office", "🏢"), ("computer", "💻"), ("phone", "📱"),
        ("camera", "📷"), ("book", "📖"), ("pencil", "✏️"), ("pen", "🖊️"),
        ("memo", "📝"), ("calendar", "📅"), ("clock", "🕒"), ("hourglass", "⏳"),
        ("bell", "🔔"), ("mail", "✉️"), ("email", "✉️"), ("inbox", "📥"), ("outbox", "📤"),
        ("link", "🔗"), ("lock", "🔒"), ("unlock", "🔓"), ("key", "🔑"),
        ("warning", "⚠️"), ("check", "✅"), ("checkmark", "✅"), ("x", "❌"), ("cross", "❌"),
        ("question", "❓"), ("exclamation", "❗"), ("info", "ℹ️"),
        ("money", "💰"), ("dollar", "💵"),
        ("chart_up", "📈"), ("chart_down", "📉"), ("bar_chart", "📊"),
        ("bulb", "💡"), ("idea", "💡"), ("gear", "⚙️"), ("wrench", "🔧"), ("hammer", "🔨"),
        ("gift", "🎁"), ("cake", "🍰"), ("coffee", "☕"), ("beer", "🍺"),
        ("pizza", "🍕"), ("burger", "🍔"), ("apple", "🍎"),
        ("dog", "🐶"), ("cat", "🐱"), ("poop", "💩"), ("skull", "💀"),
        ("ghost", "👻"), ("alien", "👽"), ("robot", "🤖"),
        ("eyes", "👀"), ("eye", "👁️"), ("brain", "🧠"),
        ("tada", "🎉"), ("party", "🎉"), ("balloon", "🎈"), ("trophy", "🏆"), ("medal", "🏅"),
    ]

    static func match(prefix: String, limit: Int = 5) -> [(shortcode: String, glyph: String)] {
        let p = prefix.lowercased()
        guard !p.isEmpty else { return [] }
        var exact: [(String, String)] = []
        var prefixed: [(String, String)] = []
        for (k, v) in table {
            if k == p { exact.append((k, v)) }
            else if k.hasPrefix(p) { prefixed.append((k, v)) }
        }
        prefixed.sort { a, b in
            if a.0.count != b.0.count { return a.0.count < b.0.count }
            return a.0 < b.0
        }
        return Array((exact + prefixed).prefix(limit))
    }
}
