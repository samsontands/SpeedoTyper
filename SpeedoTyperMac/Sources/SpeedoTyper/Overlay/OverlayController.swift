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
        hosting.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.orderOut(nil)
    }

    func show(suggestion: String, typed: String, allowMouseFallback: Bool) {
        let remaining: String = {
            if suggestion.lowercased().hasPrefix(typed.lowercased()) {
                return String(suggestion.dropFirst(typed.count))
            }
            return suggestion
        }()
        guard !remaining.isEmpty else { hide(); return }
        let anchor: CaretAnchor
        if let caret = caretAnchor() {
            anchor = caret
        } else if allowMouseFallback {
            let mouse = NSEvent.mouseLocation
            anchor = CaretAnchor(
                lineRect: CGRect(x: mouse.x, y: mouse.y + 4, width: 0, height: 18),
                font: NSFont.systemFont(ofSize: 13)
            )
        } else {
            hide()
            return
        }
        model.remaining = remaining
        model.font = anchor.font
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let origin = CGPoint(x: anchor.lineRect.minX, y: anchor.lineRect.minY + 2)
        let framed = clampToVisibleScreen(NSRect(origin: origin, size: size))
        NSLog("[SpeedoTyper] overlay remaining='%@' at %.0f,%.0f font=%@ %.1f",
              remaining, framed.origin.x, framed.origin.y,
              anchor.font.fontName, anchor.font.pointSize)
        panel.setFrame(framed, display: true)
        panel.orderFrontRegardless()
    }

    func showEmoji(typed: String, matches: [(shortcode: String, glyph: String)]) {
        let preview = matches.prefix(4).map { "\($0.glyph) :\($0.shortcode)" }.joined(separator: "  ")
        show(suggestion: "  " + preview, typed: "", allowMouseFallback: true)
    }

    func hide() {
        panel.orderOut(nil)
    }

    // MARK: - Caret tracking

    private struct CaretAnchor {
        var lineRect: CGRect
        var font: NSFont
    }

    private func caretAnchor() -> CaretAnchor? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        let el = element as! AXUIElement

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let range = rangeValue,
              CFGetTypeID(range) == AXValueGetTypeID() else { return nil }

        var selectedRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(range as! AXValue, .cfRange, &selectedRange) else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, "AXBoundsForRange" as CFString, range, &boundsValue) == .success,
              let bounds = boundsValue else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        guard rect.size.height > 0 else { return nil }

        // AX coords are top-left origin relative to the primary screen.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let lineRect = CGRect(
            x: rect.maxX,
            y: screenHeight - rect.maxY,
            width: 0,
            height: rect.height
        )
        let font = fontBeforeCaret(in: el, location: selectedRange.location, caretHeight: rect.height)
        return CaretAnchor(lineRect: lineRect, font: font)
    }

    private func fontBeforeCaret(in element: AXUIElement, location: CFIndex, caretHeight: CGFloat) -> NSFont {
        let fallbackSize = min(max(caretHeight / 1.2, 11), 24)
        let fallback = NSFont.systemFont(ofSize: fallbackSize)
        var fontRange = CFRange(location: max(0, location - 1), length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &fontRange) else { return fallback }

        var attributedValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXAttributedStringForRange" as CFString,
            rangeValue,
            &attributedValue
        ) == .success,
              let attributedValue else { return fallback }

        let attributed = attributedValue as! NSAttributedString
        guard attributed.length > 0,
              let detected = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            return fallback
        }
        return detected
    }

    private func clampToVisibleScreen(_ rect: NSRect) -> NSRect {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(rect.origin) })
              ?? NSScreen.main ?? NSScreen.screens.first else { return rect }
        let visible = screen.visibleFrame
        var r = rect
        r.origin.x = min(max(r.origin.x, visible.minX + 4), visible.maxX - r.width - 4)
        r.origin.y = min(max(r.origin.y, visible.minY + 4), visible.maxY - r.height - 4)
        return r
    }
}
