import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: ConfigStore!
    private var predictor: CompositePredictor!
    private var overlay: OverlayController!
    private var engine: KeyboardEngine!
    private var statusItem: NSStatusItem?
    private var settings: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = ConfigStore()

        let ngram = NGramPredictor(url: config.ngramURL)
        ngram.load()

        var llm: (any Predictor)? = nil
        if config.config.enableLLM, let modelURL = config.resolveModel() {
            llm = LLMPredictor(
                modelPath: modelURL.path,
                nCtx: Int32(config.config.nCtx),
                nGpuLayers: Int32(config.config.nGpuLayers),
                customInstructions: config.config.customInstructions
            )
            NSLog("[SpeedoTyper] loading GGUF from \(modelURL.path)")
        } else {
            NSLog("[SpeedoTyper] no GGUF found — running n-gram only. Set SPEEDOTYPER_MODEL or install Cotypist.")
        }
        predictor = CompositePredictor(ngram: ngram, llm: llm)

        overlay = OverlayController()
        engine = KeyboardEngine(predictor: predictor, overlay: overlay, store: config)

        settings = SettingsWindowController(model: SettingsModel(store: config))
        installStatusItem()
        schedulePeriodicSave(ngram: ngram)

        if !hasAccessibilityPermission(prompt: false) {
            // First launch — show settings so the user can see the permission state.
            settings.show()
        }

        if !hasAccessibilityPermission(prompt: true) {
            NSLog("[SpeedoTyper] Accessibility permission required — grant it in System Settings and relaunch.")
            return
        }
        engine.start()
        NSLog("[SpeedoTyper] started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
        predictor?.ngram.save()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⌨︎"
        let menu = NSMenu()
        menu.addItem(.init(title: "SpeedoTyper", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        menu.addItem(.init(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        self.statusItem = item
    }

    @MainActor
    @objc private func openSettings() {
        settings.show()
    }

    private func schedulePeriodicSave(ngram: NGramPredictor) {
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            ngram.save()
        }
    }
}

func hasAccessibilityPermission(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}
