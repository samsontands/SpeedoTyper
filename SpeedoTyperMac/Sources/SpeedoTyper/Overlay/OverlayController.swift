import AppKit
import SwiftUI
import ApplicationServices

@MainActor
final class OverlayController {
    private let panel: NSPanel
    private let hosting: NSHostingView<OverlayView>
    private let model = OverlayModel()

    init() {
        hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 36)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.orderOut(nil)
    }

    func show(typed: String, suggestion: String, hint: String = "Tab ⇥") {
        let remaining: String = {
            if suggestion.lowercased().hasPrefix(typed.lowercased()) {
                return String(suggestion.dropFirst(typed.count))
            }
            return suggestion
        }()
        guard !remaining.isEmpty else { hide(); return }
        model.typed = typed
        model.remaining = remaining
        model.hint = hint
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let origin = caretBottomLeft() ?? mouseBottomLeft()
        let frame = NSRect(
            origin: CGPoint(x: origin.x + 14, y: origin.y - size.height - 6),
            size: size
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func showEmoji(typed: String, matches: [(shortcode: String, glyph: String)]) {
        let preview = matches.prefix(4).map { "\($0.glyph) :\($0.shortcode)" }.joined(separator: "  ")
        show(typed: typed, suggestion: "  " + preview)
    }

    func hide() {
        panel.orderOut(nil)
    }

    // MARK: - Caret tracking

    private func caretBottomLeft() -> CGPoint? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        let el = element as! AXUIElement

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let range = rangeValue else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, "AXBoundsForRange" as CFString, range, &boundsValue) == .success,
              let bounds = boundsValue else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        // AX coords are top-left origin; AppKit is bottom-left. Flip.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: rect.maxX, y: screenHeight - rect.maxY)
    }

    private func mouseBottomLeft() -> CGPoint {
        NSEvent.mouseLocation
    }
}
