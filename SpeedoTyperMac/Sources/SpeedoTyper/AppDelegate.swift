import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: ConfigStore!
    private var predictor: CompositePredictor!
    private var overlay: OverlayController!
    private var engine: KeyboardEngine!
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = ConfigStore()

        let ngram = NGramPredictor(url: config.ngramURL)
        ngram.load()
        let llm: (any Predictor)? = nil  // TODO: LLMPredictor(llama.cpp bridge)
        predictor = CompositePredictor(ngram: ngram, llm: llm)

        overlay = OverlayController()
        engine = KeyboardEngine(predictor: predictor, overlay: overlay)

        installStatusItem()
        schedulePeriodicSave(ngram: ngram)

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
        menu.addItem(.init(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        self.statusItem = item
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
