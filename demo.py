"""Standalone demo — a plain text editor with inline ghost suggestions.

Use this to test the prediction engine without granting Accessibility
permissions. Ghost text is rendered directly inside the Text widget.

Tab        accept full completion
`          accept only the next word
Esc        dismiss suggestion
Type ":"   emoji suggestions
"""

from __future__ import annotations

import tkinter as tk
from tkinter import ttk

from config import ConfigStore, Statistics, NGRAM_PATH
from predictor import NGramPredictor, LLMPredictor, CompositePredictor
from emoji_data import match_emojis


class DemoEditor:
    def __init__(self):
        self.store = ConfigStore()
        self.stats = Statistics()
        self.ngram = NGramPredictor(NGRAM_PATH)
        self.llm = LLMPredictor(self.store.config.model_id) if self.store.config.enable_llm else None
        self.predictor = CompositePredictor(
            self.ngram, self.llm,
            on_llm_result=self._on_llm_result,
        )

        self.root = tk.Tk()
        self.root.title("SpeedoTyper — Demo")
        self.root.geometry("820x520")
        self.root.configure(bg="#1d1f24")

        header = tk.Frame(self.root, bg="#1d1f24")
        header.pack(fill=tk.X, padx=16, pady=(14, 6))
        tk.Label(header, text="SpeedoTyper Demo",
                 bg="#1d1f24", fg="#ffffff",
                 font=("SF Pro Display", 16, "bold")).pack(side=tk.LEFT)
        self.status = tk.Label(header, text="",
                               bg="#1d1f24", fg="#8a8f99",
                               font=("SF Pro Text", 11))
        self.status.pack(side=tk.RIGHT)

        hint = tk.Label(
            self.root,
            text="Type freely. Tab ⇥ accept · ` next word · Esc dismiss · ':name' for emoji",
            bg="#1d1f24", fg="#8a8f99", font=("SF Pro Text", 11))
        hint.pack(anchor="w", padx=18, pady=(0, 6))

        self.text = tk.Text(
            self.root, wrap=tk.WORD, bg="#272a31", fg="#ffffff",
            insertbackground="#ffffff", font=("SF Mono", 14),
            bd=0, padx=14, pady=14, undo=True,
        )
        self.text.pack(fill=tk.BOTH, expand=True, padx=16, pady=(0, 12))
        self.text.tag_configure("ghost", foreground="#8a8f99")
        self.text.tag_configure("emoji_hint", foreground="#c5c9d2",
                                background="#3a3e47")

        self.text.bind("<KeyRelease>", self._on_key_release)
        self.text.bind("<Key>", self._on_key_press)

        self.context: list[str] = []
        self.suggestion: str = ""
        self.ghost_start: str | None = None
        self.in_emoji = False
        self.emoji_query = ""

        self.root.after(500, self._refresh_status)

    # ---- status bar ---------------------------------------------------------

    def _refresh_status(self):
        if self.llm:
            self.status.configure(text=self.llm.status())
        self.root.after(1500, self._refresh_status)

    # ---- editor events ------------------------------------------------------

    def _on_key_press(self, event: tk.Event):
        if self.suggestion and event.keysym == "Tab":
            self._accept(full=True)
            return "break"
        if self.suggestion and event.char == "`":
            self._accept(full=False)
            return "break"
        if self.suggestion and event.keysym == "Escape":
            self._clear_ghost()
            return "break"
        if event.keysym in ("Left", "Right", "Up", "Down", "Home", "End"):
            self._clear_ghost()
        return None

    def _on_key_release(self, _event):
        self._clear_ghost()
        self._update_context()
        text_cursor = self.text.get("1.0", tk.INSERT)
        if not text_cursor:
            return
        last = text_cursor[-1]

        if self.in_emoji:
            if last == ":":
                self._commit_emoji_if_match()
                return
            if last.isalpha() or last == "_":
                self.emoji_query += last
                self._show_emoji_hint()
                return
            if last == " " or last == "\n":
                self._exit_emoji()
                return

        if last == ":" and self.store.config.enable_emoji_suggestions:
            self.in_emoji = True
            self.emoji_query = ""
            self.status.configure(text="Emoji mode — type a name, then ':' to insert")
            return

        word = self._current_word()
        if not word:
            return
        fast = self.predictor.predict_fast(self.context, word)
        if fast and len(fast) > len(word):
            self._show_ghost(fast[len(word):])
            self.suggestion = fast
        self.predictor.request_llm(self.context, word)

    def _on_llm_result(self, prefix: str, suggestion: str):
        def apply():
            word = self._current_word()
            if word != prefix:
                return
            if not suggestion.lower().startswith(word.lower()):
                return
            self._clear_ghost()
            self._show_ghost(suggestion[len(word):])
            self.suggestion = suggestion
        self.root.after(0, apply)

    # ---- ghost rendering ----------------------------------------------------

    def _show_ghost(self, text: str):
        if not text:
            return
        self.ghost_start = self.text.index(tk.INSERT)
        self.text.insert(self.ghost_start, text, ("ghost",))
        self.text.mark_set(tk.INSERT, self.ghost_start)

    def _clear_ghost(self):
        if not self.ghost_start:
            self.suggestion = ""
            return
        end = self.text.index(f"{self.ghost_start} lineend")
        ranges = self.text.tag_ranges("ghost")
        if ranges:
            self.text.delete(ranges[0], ranges[1])
        self.ghost_start = None
        self.suggestion = ""

    def _accept(self, full: bool):
        if not self.suggestion:
            return
        word = self._current_word()
        remaining_full = self.suggestion[len(word):]
        if full:
            insertion = remaining_full
        else:
            space_idx = remaining_full.find(" ")
            insertion = remaining_full if space_idx == -1 else remaining_full[:space_idx]
        if self.store.config.include_trailing_space:
            insertion += " "

        self._clear_ghost()
        self.text.insert(tk.INSERT, insertion)
        self.stats.record(insertion.strip())

    # ---- emoji --------------------------------------------------------------

    def _show_emoji_hint(self):
        matches = match_emojis(self.emoji_query, limit=5)
        if matches:
            preview = "  ".join(f"{g} :{k}" for k, g in matches)
            self.status.configure(text=f"Emoji: {preview}  — type ':' to insert first")
        else:
            self.status.configure(text=f"Emoji: no match for :{self.emoji_query}")

    def _commit_emoji_if_match(self):
        matches = match_emojis(self.emoji_query, limit=1)
        if matches:
            _, glyph = matches[0]
            start = self.text.index(f"{tk.INSERT} - {len(self.emoji_query) + 2} chars")
            self.text.delete(start, tk.INSERT)
            self.text.insert(tk.INSERT, glyph)
            self.stats.record(glyph)
        self._exit_emoji()

    def _exit_emoji(self):
        self.in_emoji = False
        self.emoji_query = ""
        self.status.configure(text="")

    # ---- helpers ------------------------------------------------------------

    def _current_word(self) -> str:
        text = self.text.get("1.0", tk.INSERT)
        i = len(text) - 1
        while i >= 0 and (text[i].isalpha() or text[i] == "'"):
            i -= 1
        return text[i + 1:]

    def _update_context(self):
        text = self.text.get("1.0", tk.INSERT)
        words = [w.lower() for w in text.replace("\n", " ").split() if w.isalpha()]
        self.context = words[-12:]

    def run(self):
        self.root.mainloop()
        self.ngram.save()
        self.stats.save()


def run_demo():
    DemoEditor().run()


if __name__ == "__main__":
    run_demo()
