"""Preferences window with a sidebar layout.

Mirrors the sections of Cotypist's preferences: Setup, General, Context,
Personalization, Emoji, Shortcuts, App Settings, Statistics, About.
"""

from __future__ import annotations

import sys
import tkinter as tk
from tkinter import ttk, messagebox
from typing import Callable, Optional

from config import ConfigStore, Statistics


SECTIONS = [
    ("Setup", "\U0001F4E5"),
    ("General", "\u2699\ufe0f"),
    ("Context", "\U0001F9ED"),
    ("Personalization", "\u2728"),
    ("Emoji", "\U0001F60A"),
    ("Shortcuts", "\u2318"),
    ("App Settings", "\U0001F4F1"),
    ("Statistics", "\U0001F4CA"),
    ("About", "\u2139\ufe0f"),
]


class Toggle(tk.Canvas):
    """A simple iOS-style switch."""

    def __init__(self, parent, value: bool, command: Callable[[bool], None]):
        super().__init__(parent, width=46, height=26, bg=parent["bg"], highlightthickness=0)
        self.value = value
        self.command = command
        self._draw()
        self.bind("<Button-1>", self._toggle)

    def _draw(self):
        self.delete("all")
        bg = "#34c759" if self.value else "#c7c9cc"
        self.create_oval(1, 1, 25, 25, fill=bg, outline=bg)
        self.create_oval(21, 1, 45, 25, fill=bg, outline=bg)
        self.create_rectangle(13, 1, 33, 25, fill=bg, outline=bg)
        x = 22 if self.value else 2
        self.create_oval(x, 2, x + 22, 24, fill="#ffffff", outline="#ffffff")

    def _toggle(self, _event=None):
        self.value = not self.value
        self._draw()
        self.command(self.value)

    def set(self, v: bool):
        self.value = v
        self._draw()


class Section(tk.Frame):
    """Base for detail panels on the right."""

    def __init__(self, parent, store: ConfigStore):
        super().__init__(parent, bg="#ffffff")
        self.store = store
        self.rows = tk.Frame(self, bg="#ffffff")
        self.rows.pack(fill=tk.BOTH, expand=True, padx=24, pady=20)

    def add_toggle_row(self, title: str, description: str, attr: str):
        row = tk.Frame(self.rows, bg="#ffffff")
        row.pack(fill=tk.X, pady=(0, 14))
        text = tk.Frame(row, bg="#ffffff")
        text.pack(side=tk.LEFT, fill=tk.X, expand=True)
        tk.Label(text, text=title, bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Text", 13, "bold"), anchor="w").pack(fill=tk.X)
        tk.Label(text, text=description, bg="#ffffff", fg="#6e6e73",
                 font=("SF Pro Text", 11), anchor="w", justify=tk.LEFT,
                 wraplength=440).pack(fill=tk.X, pady=(2, 0))
        val = getattr(self.store.config, attr)
        toggle = Toggle(row, val, lambda v: self._set(attr, v))
        toggle.pack(side=tk.RIGHT, padx=(10, 0), pady=6)

    def add_static_row(self, title: str, description: str, status_text: str):
        row = tk.Frame(self.rows, bg="#ffffff")
        row.pack(fill=tk.X, pady=(0, 14))
        text = tk.Frame(row, bg="#ffffff")
        text.pack(side=tk.LEFT, fill=tk.X, expand=True)
        tk.Label(text, text=title, bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Text", 13, "bold"), anchor="w").pack(fill=tk.X)
        tk.Label(text, text=description, bg="#ffffff", fg="#6e6e73",
                 font=("SF Pro Text", 11), anchor="w", justify=tk.LEFT,
                 wraplength=440).pack(fill=tk.X, pady=(2, 0))
        tk.Label(row, text=status_text, bg="#e8e8ed", fg="#1d1d1f",
                 font=("SF Pro Text", 11), padx=10, pady=4).pack(side=tk.RIGHT, padx=(10, 0))

    def _set(self, attr: str, value):
        self.store.update(**{attr: value})


class SetupSection(Section):
    def __init__(self, parent, store: ConfigStore, permissions: dict):
        super().__init__(parent, store)
        tk.Label(self.rows, text="\u2705  All Set!", bg="#ffffff", fg="#2b9348",
                 font=("SF Pro Display", 16, "bold")).pack(anchor="w")
        tk.Label(self.rows,
                 text="SpeedoTyper is ready to use. Close this window or tweak the other settings.",
                 bg="#ffffff", fg="#6e6e73", font=("SF Pro Text", 12),
                 wraplength=520, justify=tk.LEFT).pack(anchor="w", pady=(4, 18))
        self.add_static_row("Accessibility Permission",
                            "Required to capture keystrokes across apps.",
                            "Granted" if permissions.get("accessibility") else "Needed")
        self.add_static_row("Screen Recording Permission",
                            "Recommended for better context-aware suggestions.",
                            "Granted" if permissions.get("screen") else "Optional")
        self.add_static_row("AI Model Download",
                            f"Download the AI model used for completions.",
                            "Downloaded" if permissions.get("model") else "Pending")
        self.add_toggle_row("macOS Text Suggestions",
                            "Disable built-in suggestions to avoid conflicts with SpeedoTyper.",
                            "macos_text_suggestions_disabled")
        self.add_toggle_row("Clipboard Context",
                            "Enable clipboard context for more relevant completions. "
                            "Clipboard contents are processed locally and never stored or sent.",
                            "use_clipboard_context")


class GeneralSection(Section):
    def __init__(self, parent, store: ConfigStore):
        super().__init__(parent, store)
        self.add_toggle_row("Launch automatically at login",
                            "", "launch_at_login")
        self.add_toggle_row("Show Status Item",
                            "Display the SpeedoTyper icon in the menu bar for quick access.",
                            "show_status_item")
        self.add_toggle_row("Show Accessory Button",
                            "A floating button that provides quick access in text fields.",
                            "show_accessory_button")

        tk.Label(self.rows, text="AI Settings", bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Display", 14, "bold")).pack(anchor="w", pady=(10, 6))
        row = tk.Frame(self.rows, bg="#ffffff")
        row.pack(fill=tk.X, pady=(0, 14))
        tk.Label(row, text="AI Model", bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Text", 13, "bold")).pack(side=tk.LEFT)
        tk.Label(row, text=f"\u2705  {self.store.config.model_label}",
                 bg="#eaf7ee", fg="#1d1d1f", padx=10, pady=4,
                 font=("SF Pro Text", 12)).pack(side=tk.RIGHT)
        tk.Label(self.rows, text="Recommended for your system: Gemma 4 E2B",
                 bg="#ffffff", fg="#6e6e73",
                 font=("SF Pro Text", 11)).pack(anchor="w", pady=(0, 14))

        tk.Label(self.rows, text="Completion Settings", bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Display", 14, "bold")).pack(anchor="w", pady=(10, 6))
        self.add_toggle_row("Enable Completions by Default",
                            "Turn off to disable globally. Use App Settings for per-app overrides.",
                            "enable_completions")

        row = tk.Frame(self.rows, bg="#ffffff")
        row.pack(fill=tk.X, pady=(0, 14))
        tk.Label(row, text="Maximum Completion Length", bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Text", 13, "bold")).pack(anchor="w")
        tk.Label(row, text="Longer completions are slower but cover more ground.",
                 bg="#ffffff", fg="#6e6e73",
                 font=("SF Pro Text", 11)).pack(anchor="w", pady=(2, 6))
        var = tk.StringVar(value=self.store.config.max_completion_length)
        opts = ttk.Combobox(row, textvariable=var, state="readonly",
                            values=["short", "medium", "long"])
        opts.pack(anchor="w")
        opts.bind("<<ComboboxSelected>>",
                  lambda _e: self.store.update(max_completion_length=var.get()))


class ContextSection(Section):
    def __init__(self, parent, store: ConfigStore):
        super().__init__(parent, store)
        tk.Label(self.rows, text="Screenshot Settings", bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Display", 14, "bold")).pack(anchor="w", pady=(0, 6))
        self.add_toggle_row("Use screenshots for context",
                            "Reads your screen to understand the surrounding context. "
                            "Screen contents are processed locally and are never stored or sent.",
                            "use_screenshot_context")
        self.add_toggle_row("Improve suggestion positioning",
                            "Uses screen reading to place the ghost text more accurately.",
                            "improve_suggestion_positioning")

        tk.Label(self.rows, text="Clipboard Settings", bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Display", 14, "bold")).pack(anchor="w", pady=(14, 6))
        self.add_toggle_row("Use clipboard for context",
                            "Reads your clipboard when suggesting completions to understand what "
                            "you're working on. Processed locally; never stored or sent.",
                            "use_clipboard_context")


class PersonalizationSection(Section):
    def __init__(self, parent, store: ConfigStore):
        super().__init__(parent, store)
        tk.Label(self.rows, text="Typing History", bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Display", 14, "bold")).pack(anchor="w", pady=(0, 6))
        self.add_toggle_row("Collect Inputs for Personalization",
                            "Stores the contents of text fields SpeedoTyper is activated in "
                            "to improve completions. All data encrypted locally.",
                            "collect_inputs")
        self.add_toggle_row("Store Inputs Without Accepted Completions",
                            "Store inputs even when no completion is accepted.",
                            "store_without_accepted")

        row = tk.Frame(self.rows, bg="#ffffff")
        row.pack(fill=tk.X, pady=(0, 14))
        tk.Label(row, text="Personalize Word Choice", bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Text", 13, "bold")).pack(anchor="w")
        tk.Label(row, text="Bias suggestions toward your past usage. "
                           "Higher values may suggest less fitting words.",
                 bg="#ffffff", fg="#6e6e73",
                 font=("SF Pro Text", 11)).pack(anchor="w", pady=(2, 6))
        scale = tk.Scale(row, from_=0.0, to=1.0, resolution=0.05,
                         orient=tk.HORIZONTAL, bg="#ffffff",
                         length=300, showvalue=True,
                         command=lambda v: self.store.update(personalize_weight=float(v)))
        scale.set(self.store.config.personalize_weight)
        scale.pack(anchor="w")

        tk.Label(self.rows, text="Custom AI Instructions", bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Display", 14, "bold")).pack(anchor="w", pady=(14, 6))
        tk.Label(self.rows,
                 text="Customize how SpeedoTyper completes your text with your own instructions. "
                      "Keep it short for best performance.",
                 bg="#ffffff", fg="#6e6e73", wraplength=520, justify=tk.LEFT,
                 font=("SF Pro Text", 11)).pack(anchor="w", pady=(0, 6))

        self.text = tk.Text(self.rows, height=6, width=60, wrap=tk.WORD,
                            font=("SF Mono", 12), bd=1, relief=tk.SOLID,
                            highlightbackground="#d2d2d7", padx=10, pady=10)
        self.text.insert("1.0", self.store.config.custom_instructions)
        self.text.pack(anchor="w", fill=tk.X)
        self.text.bind("<FocusOut>", self._save)

    def _save(self, _e):
        self.store.update(custom_instructions=self.text.get("1.0", tk.END).strip())


class EmojiSection(Section):
    def __init__(self, parent, store: ConfigStore):
        super().__init__(parent, store)
        self.add_toggle_row("Enable Emoji Suggestions",
                            'Show emoji suggestions when you type ":". You can type after the '
                            'colon to filter (e.g. ":heart"). Use macOS emoji picker (\u2303\u2318 Space) as fallback.',
                            "enable_emoji_suggestions")


class ShortcutsSection(Section):
    def __init__(self, parent, store: ConfigStore):
        super().__init__(parent, store)
        self._kv("Complete only the next word",
                 "Accept just one word at a time; tap repeatedly to chain.",
                 "accept_word_key")
        self.add_toggle_row("Include trailing space",
                            "Append a space after single-word completions.",
                            "include_trailing_space")
        self._kv("Trigger full completion",
                 "Accept the entire suggested completion.",
                 "accept_full_key")
        self._kv("Force-activate completions",
                 "Invoke a completion when one didn't appear automatically.",
                 "force_activate_key")
        self._kv("Temporarily toggle in current app",
                 "Turn completions off for a few minutes in the current app.",
                 "toggle_current_app_key")
        self._kv("Toggle completions globally",
                 "Disable completions everywhere until pressed again.",
                 "toggle_global_key")

    def _kv(self, title: str, desc: str, attr: str):
        row = tk.Frame(self.rows, bg="#ffffff")
        row.pack(fill=tk.X, pady=(0, 14))
        text = tk.Frame(row, bg="#ffffff")
        text.pack(side=tk.LEFT, fill=tk.X, expand=True)
        tk.Label(text, text=title, bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Text", 13, "bold"), anchor="w").pack(fill=tk.X)
        tk.Label(text, text=desc, bg="#ffffff", fg="#6e6e73",
                 font=("SF Pro Text", 11), anchor="w", wraplength=420,
                 justify=tk.LEFT).pack(fill=tk.X, pady=(2, 0))
        val = getattr(self.store.config, attr)
        entry = tk.Entry(row, font=("SF Mono", 12), width=14, justify=tk.CENTER)
        entry.insert(0, val)
        entry.pack(side=tk.RIGHT, padx=(10, 0))
        entry.bind("<FocusOut>",
                   lambda _e, a=attr, en=entry: self.store.update(**{a: en.get().strip()}))


class AppSettingsSection(Section):
    def __init__(self, parent, store: ConfigStore):
        super().__init__(parent, store)
        tk.Label(self.rows, text="Per-app overrides",
                 bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Display", 14, "bold")).pack(anchor="w", pady=(0, 6))
        tk.Label(self.rows,
                 text="Disable SpeedoTyper inside specific apps. "
                      "Type an app name and toggle.",
                 bg="#ffffff", fg="#6e6e73",
                 font=("SF Pro Text", 11), wraplength=520,
                 justify=tk.LEFT).pack(anchor="w", pady=(0, 10))

        entry_row = tk.Frame(self.rows, bg="#ffffff")
        entry_row.pack(fill=tk.X, pady=(0, 10))
        self.entry = tk.Entry(entry_row, font=("SF Pro Text", 12), width=30)
        self.entry.pack(side=tk.LEFT)
        tk.Button(entry_row, text="Add", command=self._add).pack(side=tk.LEFT, padx=(8, 0))

        self.list_frame = tk.Frame(self.rows, bg="#ffffff")
        self.list_frame.pack(fill=tk.BOTH, expand=True)
        self._refresh()

    def _add(self):
        name = self.entry.get().strip()
        if not name:
            return
        apps = dict(self.store.config.app_overrides)
        apps[name] = {"enabled": False}
        self.store.update(app_overrides=apps)
        self.entry.delete(0, tk.END)
        self._refresh()

    def _refresh(self):
        for w in self.list_frame.winfo_children():
            w.destroy()
        for name, cfg in self.store.config.app_overrides.items():
            row = tk.Frame(self.list_frame, bg="#ffffff")
            row.pack(fill=tk.X, pady=4)
            tk.Label(row, text=name, bg="#ffffff",
                     font=("SF Pro Text", 12)).pack(side=tk.LEFT)
            Toggle(row, cfg.get("enabled", True),
                   lambda v, n=name: self._set(n, v)).pack(side=tk.RIGHT)
            tk.Button(row, text="\u2212", width=2,
                      command=lambda n=name: self._remove(n)).pack(side=tk.RIGHT, padx=(0, 6))

    def _set(self, name: str, enabled: bool):
        apps = dict(self.store.config.app_overrides)
        apps[name] = {"enabled": enabled}
        self.store.update(app_overrides=apps)

    def _remove(self, name: str):
        apps = dict(self.store.config.app_overrides)
        apps.pop(name, None)
        self.store.update(app_overrides=apps)
        self._refresh()


class StatisticsSection(Section):
    def __init__(self, parent, store: ConfigStore, stats: Statistics):
        super().__init__(parent, store)
        self.stats = stats

        today = stats.today()
        tk.Label(self.rows, text="Today's Activity", bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Display", 14, "bold")).pack(anchor="w")
        row = tk.Frame(self.rows, bg="#ffffff")
        row.pack(fill=tk.X, pady=(8, 20))
        for label, val in (("Completions", today.completions),
                           ("Words", today.words),
                           ("Characters", today.characters)):
            col = tk.Frame(row, bg="#f5f5f7", padx=14, pady=10)
            col.pack(side=tk.LEFT, padx=(0, 10))
            tk.Label(col, text=label, bg="#f5f5f7", fg="#6e6e73",
                     font=("SF Pro Text", 11)).pack(anchor="w")
            tk.Label(col, text=str(val), bg="#f5f5f7", fg="#1d1d1f",
                     font=("SF Pro Display", 18, "bold")).pack(anchor="w")

        tk.Label(self.rows, text="Completion Statistics (Last 30 Days)",
                 bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Display", 14, "bold")).pack(anchor="w")

        canvas = tk.Canvas(self.rows, height=180, bg="#ffffff",
                           highlightthickness=0)
        canvas.pack(fill=tk.X, pady=(10, 10))
        self.rows.update_idletasks()
        canvas.update_idletasks()
        self._draw_bars(canvas)

        t = stats.total()
        footer = tk.Frame(self.rows, bg="#ffffff")
        footer.pack(fill=tk.X)
        tk.Label(footer, text=f"Total  {t.completions}",
                 bg="#ffffff", font=("SF Pro Text", 12)).pack(side=tk.LEFT, padx=(0, 24))
        days = max(1, len(stats.by_day))
        tk.Label(footer, text=f"Daily Average (Active Days)  {t.completions // days}",
                 bg="#ffffff", font=("SF Pro Text", 12)).pack(side=tk.LEFT)

    def _draw_bars(self, canvas: tk.Canvas):
        canvas.update_idletasks()
        width = max(canvas.winfo_width(), 500)
        height = 160
        data = self.stats.recent(30)
        if not data:
            canvas.create_text(width // 2, height // 2,
                               text="No data yet. Start typing to see stats.",
                               fill="#6e6e73", font=("SF Pro Text", 12))
            return
        max_val = max((d.words for _, d in data), default=1) or 1
        n = len(data)
        bw = max(4, (width - 40) / n - 4)
        x = 20
        for day, d in data:
            h = (d.words / max_val) * (height - 30)
            canvas.create_rectangle(x, height - h, x + bw, height,
                                    fill="#4a8bf5", outline="")
            x += bw + 4


class AboutSection(Section):
    def __init__(self, parent, store: ConfigStore):
        super().__init__(parent, store)
        header = tk.Frame(self.rows, bg="#ffffff")
        header.pack(fill=tk.X, pady=(0, 14))
        tk.Label(header, text="SpeedoTyper 0.1.0", bg="#ffffff",
                 fg="#1d1d1f", font=("SF Pro Display", 18, "bold")).pack(anchor="w")
        tk.Label(header,
                 text="An open-source AI autocomplete for Mac. "
                      "Inspired by Cotypist.",
                 bg="#ffffff", fg="#6e6e73",
                 font=("SF Pro Text", 12)).pack(anchor="w", pady=(4, 0))

        tk.Label(self.rows, text="Third-Party Acknowledgments",
                 bg="#ffffff", fg="#1d1d1f",
                 font=("SF Pro Display", 14, "bold")).pack(anchor="w", pady=(10, 4))

        for name, note in [
            ("Google Gemma", "Gemma is provided under and subject to the Gemma Terms of Use."),
            ("mlx / mlx-lm", "Apple — on-device inference runtime."),
            ("llama.cpp", "ggml authors — alternative inference runtime."),
            ("pynput", "Keyboard monitoring and injection."),
            ("pyobjc", "macOS system integration."),
            ("Tcl/Tk", "GUI toolkit used for the preferences window."),
        ]:
            tk.Label(self.rows, text=name, bg="#ffffff", fg="#2563eb",
                     font=("SF Pro Text", 12, "bold")).pack(anchor="w")
            tk.Label(self.rows, text=note, bg="#ffffff", fg="#6e6e73",
                     font=("SF Pro Text", 11)).pack(anchor="w", pady=(0, 6))


class SettingsWindow:
    def __init__(
        self,
        root: tk.Tk,
        store: ConfigStore,
        stats: Statistics,
        permissions_provider: Optional[Callable[[], dict]] = None,
    ):
        self.root = root
        self.store = store
        self.stats = stats
        self.permissions_provider = permissions_provider or (lambda: {})

        self.win = tk.Toplevel(root)
        self.win.title("SpeedoTyper")
        self.win.geometry("820x560")
        self.win.configure(bg="#ffffff")
        try:
            self.win.attributes("-topmost", False)
        except tk.TclError:
            pass

        self._build_sidebar()
        self._content_frame = tk.Frame(self.win, bg="#ffffff")
        self._content_frame.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self._current: Optional[tk.Frame] = None
        self.select("Setup")

    def _build_sidebar(self):
        bar = tk.Frame(self.win, bg="#f5f5f7", width=200)
        bar.pack(side=tk.LEFT, fill=tk.Y)
        bar.pack_propagate(False)

        tk.Label(bar, text="SpeedoTyper", bg="#f5f5f7", fg="#1d1d1f",
                 font=("SF Pro Display", 14, "bold"), pady=16).pack()
        self.buttons: dict[str, tk.Button] = {}
        for name, icon in SECTIONS:
            btn = tk.Button(
                bar, text=f"  {icon}  {name}", anchor="w",
                bg="#f5f5f7", fg="#1d1d1f", bd=0, padx=14, pady=8,
                activebackground="#e4e7ea", font=("SF Pro Text", 12),
                command=lambda n=name: self.select(n),
            )
            btn.pack(fill=tk.X, padx=8, pady=2)
            self.buttons[name] = btn

    def select(self, name: str):
        for n, b in self.buttons.items():
            b.configure(bg=("#3478f6" if n == name else "#f5f5f7"),
                        fg=("#ffffff" if n == name else "#1d1d1f"))
        if self._current:
            self._current.destroy()
        builder = {
            "Setup": lambda p: SetupSection(p, self.store, self.permissions_provider()),
            "General": lambda p: GeneralSection(p, self.store),
            "Context": lambda p: ContextSection(p, self.store),
            "Personalization": lambda p: PersonalizationSection(p, self.store),
            "Emoji": lambda p: EmojiSection(p, self.store),
            "Shortcuts": lambda p: ShortcutsSection(p, self.store),
            "App Settings": lambda p: AppSettingsSection(p, self.store),
            "Statistics": lambda p: StatisticsSection(p, self.store, self.stats),
            "About": lambda p: AboutSection(p, self.store),
        }[name]
        self._current = builder(self._content_frame)
        self._current.pack(fill=tk.BOTH, expand=True)

    def show(self):
        self.win.deiconify()
        self.win.lift()
