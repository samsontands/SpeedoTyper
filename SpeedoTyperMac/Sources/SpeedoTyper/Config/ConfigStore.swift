import Foundation

struct Config: Codable {
    var launchAtLogin: Bool = false
    var showStatusItem: Bool = true
    var enableLLM: Bool = true
    var modelID: String = "gemma-4-E2B-i1-Q4_K_M.gguf"
    var nCtx: Int = 2048
    var nGpuLayers: Int = -1
    var enableCompletions: Bool = true
    var acceptFullKey: String = "tab"
    var acceptWordKey: String = "`"
    var includeTrailingSpace: Bool = true
    var customInstructions: String =
        "Write in a friendly, professional and empathetic voice. " +
        "Keep sentences short, concise and readable."
    var enableEmojiSuggestions: Bool = true
    var appOverrides: [String: [String: Bool]] = [:]
}

final class ConfigStore {
    private(set) var config: Config
    private let baseDir: URL
    private let configURL: URL
    let ngramURL: URL
    let statsURL: URL

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let base: URL
        if let env = ProcessInfo.processInfo.environment["SPEEDOTYPER_HOME"] {
            base = URL(fileURLWithPath: env)
        } else {
            base = support.appendingPathComponent("SpeedoTyper")
        }
        self.baseDir = base
        self.configURL = base.appendingPathComponent("config.json")
        self.ngramURL = base.appendingPathComponent("ngrams.json")
        self.statsURL = base.appendingPathComponent("stats.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            self.config = decoded
        } else {
            self.config = Config()
        }
    }

    func save() {
        write(config)
    }

    func write(_ cfg: Config) {
        self.config = cfg
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        let tmp = configURL.appendingPathExtension("tmp")
        try? data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
    }

    /// Candidate paths for a pre-downloaded Gemma GGUF — matches the Python config.
    func modelCandidates() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var list: [URL] = []
        if let env = ProcessInfo.processInfo.environment["SPEEDOTYPER_MODEL"] {
            list.append(URL(fileURLWithPath: env))
        }
        list.append(baseDir.appendingPathComponent("Models").appendingPathComponent(config.modelID))
        list.append(home
            .appendingPathComponent("Library/Application Support/app.cotypist.Cotypist/Models")
            .appendingPathComponent(config.modelID))
        return list
    }

    func resolveModel() -> URL? {
        for url in modelCandidates() where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }
}
