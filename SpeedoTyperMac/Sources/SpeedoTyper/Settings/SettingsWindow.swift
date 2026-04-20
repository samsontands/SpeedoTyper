import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsRoot(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.title = "SpeedoTyper"
        w.setContentSize(NSSize(width: 760, height: 520))
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = WindowDelegate.shared
        self.window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

private final class WindowDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowDelegate()
}

// MARK: - Root view

enum SettingsPane: String, CaseIterable, Identifiable {
    case setup = "Setup"
    case general = "General"
    case context = "Context"
    case personalization = "Personalization"
    case emoji = "Emoji"
    case shortcuts = "Shortcuts"
    case apps = "App Settings"
    case stats = "Statistics"
    case about = "About"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .setup: return "checkmark.seal"
        case .general: return "gearshape"
        case .context: return "rectangle.on.rectangle"
        case .personalization: return "person.crop.circle"
        case .emoji: return "face.smiling"
        case .shortcuts: return "command"
        case .apps: return "app.badge"
        case .stats: return "chart.bar"
        case .about: return "info.circle"
        }
    }
}

struct SettingsRoot: View {
    @ObservedObject var model: SettingsModel
    @State private var selection: SettingsPane = .setup

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.rawValue, systemImage: pane.symbol)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200)
        } detail: {
            Group {
                switch selection {
                case .setup: SetupPane(model: model)
                case .general: GeneralPane(config: $model.config)
                case .context: ContextPane(config: $model.config)
                case .personalization: PersonalizationPane(config: $model.config)
                case .emoji: EmojiPane(config: $model.config)
                case .shortcuts: ShortcutsPane(config: $model.config)
                case .apps: AppsPane(config: $model.config)
                case .stats: StatsPane()
                case .about: AboutPane()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { model.refreshPermissions() }
    }
}

// MARK: - Panes

private struct SetupPane: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup").font(.title).bold()
            Text("Grant the permissions SpeedoTyper needs to watch your typing.")
                .foregroundStyle(.secondary)
            Divider()
            CheckRow(
                title: "Accessibility",
                subtitle: "Required to observe keystrokes and insert completions.",
                ok: model.permissions.accessibility
            )
            CheckRow(
                title: "Gemma 4 E2B model",
                subtitle: "~3.5 GB GGUF — reused from Cotypist if installed.",
                ok: model.permissions.model
            )
            CheckRow(
                title: "Screen Recording (optional)",
                subtitle: "Improves context awareness by OCR-ing the focused app.",
                ok: model.permissions.screen
            )
            Button("Recheck") { model.refreshPermissions() }
                .padding(.top, 8)
        }
    }
}

private struct CheckRow: View {
    let title: String
    let subtitle: String
    let ok: Bool
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct GeneralPane: View {
    @Binding var config: Config
    var body: some View {
        PaneStack(title: "General") {
            Toggle("Launch at login", isOn: $config.launchAtLogin)
            Toggle("Show menu bar icon", isOn: $config.showStatusItem)
            Toggle("Enable completions", isOn: $config.enableCompletions)
            Toggle("Use LLM (Gemma 4 E2B)", isOn: $config.enableLLM)
            HStack {
                Text("Context tokens").frame(width: 160, alignment: .leading)
                Stepper("\(config.nCtx)", value: $config.nCtx, in: 512...8192, step: 512)
            }
            Toggle("Insert trailing space on accept", isOn: $config.includeTrailingSpace)
        }
    }
}

private struct ContextPane: View {
    @Binding var config: Config
    var body: some View {
        PaneStack(title: "Context") {
            Text("Context is the signal SpeedoTyper uses to pick the right completion.")
                .foregroundStyle(.secondary)
            Toggle("Use clipboard as additional context", isOn: .constant(true)).disabled(true)
            Toggle("Use screenshot / focused-window context", isOn: .constant(false)).disabled(true)
            Toggle("Improve suggestion positioning", isOn: .constant(false)).disabled(true)
        }
    }
}

private struct PersonalizationPane: View {
    @Binding var config: Config
    var body: some View {
        PaneStack(title: "Personalization") {
            Text("Custom instructions (style guide for the LLM).")
                .font(.subheadline).foregroundStyle(.secondary)
            TextEditor(text: $config.customInstructions)
                .font(.body)
                .frame(minHeight: 120)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        }
    }
}

private struct EmojiPane: View {
    @Binding var config: Config
    var body: some View {
        PaneStack(title: "Emoji") {
            Toggle("Enable emoji shortcodes (type :name)", isOn: $config.enableEmojiSuggestions)
            Text("Built-in shortcodes (\(EmojiData.table.count)):")
                .font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], spacing: 4) {
                    ForEach(EmojiData.table, id: \.0) { (name, glyph) in
                        HStack(spacing: 6) {
                            Text(glyph)
                            Text(":\(name)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }
}

private struct ShortcutsPane: View {
    @Binding var config: Config
    var body: some View {
        PaneStack(title: "Shortcuts") {
            ShortcutRow(title: "Accept full suggestion", value: $config.acceptFullKey)
            ShortcutRow(title: "Accept next word", value: $config.acceptWordKey)
            Text("Shortcut capture UI is not yet wired up — edit the raw key names.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    @Binding var value: String
    var body: some View {
        HStack {
            Text(title).frame(width: 220, alignment: .leading)
            TextField("key", text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            Spacer()
        }
    }
}

private struct AppsPane: View {
    @Binding var config: Config
    @State private var apps: [AppInfo] = []

    struct AppInfo: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage?
    }

    var body: some View {
        PaneStack(title: "App Settings") {
            Toggle("Show ghost text at mouse when caret position is unavailable",
                   isOn: $config.mouseFallback)
            Divider()
            Text("Disable SpeedoTyper in these apps:")
                .foregroundStyle(.secondary)
            List {
                ForEach(apps) { app in
                    HStack {
                        if let img = app.icon {
                            Image(nsImage: img).resizable().frame(width: 20, height: 20)
                        }
                        Text(app.name)
                        Spacer()
                        Toggle("", isOn: binding(for: app.bundleID))
                            .labelsHidden()
                    }
                }
            }
            .frame(minHeight: 260)
        }
        .onAppear(perform: reloadApps)
    }

    private func reloadApps() {
        var seen: [String: AppInfo] = [:]
        for a in NSWorkspace.shared.runningApplications
            where a.activationPolicy == .regular {
            if let bid = a.bundleIdentifier, let name = a.localizedName {
                seen[bid] = AppInfo(bundleID: bid, name: name, icon: a.icon)
            }
        }
        for bid in config.disabledApps where seen[bid] == nil {
            seen[bid] = AppInfo(bundleID: bid, name: bid, icon: nil)
        }
        apps = seen.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func binding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { !config.disabledApps.contains(bundleID) },
            set: { enabled in
                if enabled {
                    config.disabledApps.removeAll { $0 == bundleID }
                } else if !config.disabledApps.contains(bundleID) {
                    config.disabledApps.append(bundleID)
                }
            }
        )
    }
}

private struct StatsPane: View {
    var body: some View {
        PaneStack(title: "Statistics") {
            Text("Completion and word counts per day will appear here.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        PaneStack(title: "About") {
            Text("SpeedoTyper (Swift)").font(.title2).bold()
            Text("System-wide AI autocomplete for macOS.")
            Text("Inspired by Cotypist. Uses Gemma 4 E2B via llama.cpp.")
                .foregroundStyle(.secondary)
            Link("Source: github.com/samsontands/SpeedoTyper",
                 destination: URL(string: "https://github.com/samsontands/SpeedoTyper")!)
                .padding(.top, 4)
        }
    }
}

private struct PaneStack<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title).bold()
            Divider()
            content()
        }
    }
}
