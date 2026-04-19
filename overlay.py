"""Floating ghost-text overlay window.

Shows the current suggestion as dimmed text next to a pill showing the
accept shortcut. Follows the mouse cursor position by default; on macOS,
the mouse position is an approximation for the text cursor.

Runs in the main thread; UI updates are marshalled via root.after().
"""

from __future__ import annotations

import platform
import threading
import tkinter as tk
from typing import Optional, Tuple

try:
    from Quartz import NSEvent  # type: ignore
except Exception:  # pragma: no cover
    NSEvent = None

try:
    from ApplicationServices import (  # type: ignore
        AXUIElementCreateSystemWide,
        AXUIElementCopyAttributeValue,
        AXValueGetValue,
        kAXValueCGPointType,
        kAXValueCGRectType,
    )
    _AX_OK = True
except Exception:  # pragma: no cover
    _AX_OK = False


def _screen_height() -> int:
    try:
        from AppKit import NSScreen  # type: ignore
        return int(NSScreen.mainScreen().frame().size.height)
    except Exception:
        return 0


def mouse_position() -> tuple[int, int]:
    if NSEvent is not None:
        try:
            loc = NSEvent.mouseLocation()
            h = _screen_height()
            return int(loc.x), int(h - loc.y) if h else 100
        except Exception:
            pass
    return 100, 100


def caret_position() -> Optional[tuple[int, int]]:
    """Return screen-space (x, y) of the focused field's text caret, if obtainable.

    Uses the Accessibility API:
      system -> focused UI element -> AXBoundsForRange(selected range).
    Returns None on any failure (unsupported app, no focus, permission denied).
    """
    if not _AX_OK:
        return None
    try:
        system = AXUIElementCreateSystemWide()
        err, focused = AXUIElementCopyAttributeValue(system, "AXFocusedUIElement", None)
        if err != 0 or focused is None:
            return None
        err, sel_range = AXUIElementCopyAttributeValue(focused, "AXSelectedTextRange", None)
        if err != 0 or sel_range is None:
            return None
        err, bounds = AXUIElementCopyAttributeValue(
            focused, "AXBoundsForRange", sel_range
        )
        if err != 0 or bounds is None:
            return None
        # AXBoundsForRange returns an AXValue wrapping CGRect.
        import objc  # type: ignore
        from CoreFoundation import CFGetTypeID  # type: ignore
        try:
            from Quartz import CGRect  # type: ignore
            rect = AXValueGetValue(bounds, kAXValueCGRectType, None)
        except Exception:
            return None
        if rect is None:
            return None
        # rect is (origin.x, origin.y, size.width, size.height) in screen coords,
        # bottom-left origin.
        try:
            x = int(rect.origin.x)
            y = int(rect.origin.y)
            w = int(rect.size.width)
            h = int(rect.size.height)
        except AttributeError:
            return None
        screen_h = _screen_height()
        return x + w, (screen_h - y - h) if screen_h else y
    except Exception:
        return None


def anchor_position() -> tuple[int, int]:
    """Best-effort position for the overlay: caret if available, else mouse."""
    pos = caret_position()
    return pos if pos else mouse_position()


class Overlay:
    """Tkinter-based floating overlay."""

    def __init__(self, root: tk.Tk):
        self.root = root
        self.win = tk.Toplevel(root)
        self.win.withdraw()
        self.win.overrideredirect(True)
        try:
            self.win.attributes("-topmost", True)
            self.win.attributes("-alpha", 0.96)
            if platform.system() == "Darwin":
                self.win.attributes("-transparent", True)
        except tk.TclError:
            pass

        self.frame = tk.Frame(self.win, bg="#1d1f24", bd=0)
        self.frame.pack()

        self.typed_label = tk.Label(
            self.frame,
            text="",
            bg="#1d1f24",
            fg="#ffffff",
            font=("SF Pro Text", 13),
            padx=0, pady=6,
        )
        self.typed_label.pack(side=tk.LEFT, padx=(10, 0))

        self.ghost_label = tk.Label(
            self.frame,
            text="",
            bg="#1d1f24",
            fg="#8a8f99",
            font=("SF Pro Text", 13),
            padx=0, pady=6,
        )
        self.ghost_label.pack(side=tk.LEFT)

        self.hint_label = tk.Label(
            self.frame,
            text="",
            bg="#2a2d34",
            fg="#c5c9d2",
            font=("SF Pro Text", 11),
            padx=8, pady=2,
        )
        self.hint_label.pack(side=tk.LEFT, padx=(10, 10), pady=6)

        self._visible = False
        self._follow_cursor = True

    # ---- thread-safe API ----------------------------------------------------

    def show(self, typed: str, suggestion: str, hint: str = "Tab ⇥") -> None:
        self.root.after(0, lambda: self._show(typed, suggestion, hint))

    def show_emoji(self, typed: str, matches: list[tuple[str, str]]) -> None:
        preview = "  ".join(f"{g} :{k}" for k, g in matches[:4])
        self.root.after(0, lambda: self._show(typed, "  " + preview, "Tab ⇥"))

    def hide(self) -> None:
        self.root.after(0, self._hide)

    # ---- internal -----------------------------------------------------------

    def _show(self, typed: str, suggestion: str, hint: str) -> None:
        remaining = suggestion[len(typed):] if suggestion.lower().startswith(typed.lower()) else suggestion
        if not remaining:
            self._hide()
            return
        self.typed_label.config(text=typed)
        self.ghost_label.config(text=remaining)
        self.hint_label.config(text=hint)
        self.win.update_idletasks()
        if self._follow_cursor:
            x, y = anchor_position()
            x += 14
            y += 6
            self.win.geometry(f"+{x}+{y}")
        self.win.deiconify()
        self._visible = True

    def _hide(self) -> None:
        if self._visible:
            self.win.withdraw()
            self._visible = False

    def is_visible(self) -> bool:
        return self._visible
