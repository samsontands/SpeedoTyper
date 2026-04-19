"""Global keyboard monitor + completion injection.

Runs pynput.Listener in a background thread, watches character input to
maintain the current word and rolling context, and fires suggestions
through the overlay. On Tab (or the configured accept key) it injects
the completion into whichever app has focus.

macOS requires Accessibility permission for this to function.
"""

from __future__ import annotations

import re
import threading
import time
from typing import Callable, Optional

try:
    from pynput import keyboard
    from pynput.keyboard import Controller, Key, KeyCode
except ImportError:  # pragma: no cover
    keyboard = None
    Controller = None
    Key = None
    KeyCode = None

from config import ConfigStore, Statistics
from predictor import CompositePredictor
from emoji_data import match_emojis

WORD_CHARS = re.compile(r"[A-Za-z']")


class TypingState:
    """Rolling state: current word being typed + last N completed words."""

    def __init__(self, context_size: int = 12):
        self.current_word = ""
        self.context: list[str] = []
        self.context_size = context_size
        self.in_emoji = False
        self.emoji_query = ""
        self.last_suggestion: Optional[str] = None

    def push_word(self, word: str):
        if not word:
            return
        self.context.append(word.lower())
        if len(self.context) > self.context_size:
            self.context.pop(0)

    def reset_emoji(self):
        self.in_emoji = False
        self.emoji_query = ""


def _front_app_name() -> Optional[str]:
    try:
        from AppKit import NSWorkspace  # type: ignore
        app = NSWorkspace.sharedWorkspace().frontmostApplication()
        if app:
            return str(app.localizedName())
    except Exception:
        return None
    return None


class KeyboardEngine:
    """Glue between key events, predictor and overlay."""

    def __init__(
        self,
        store: ConfigStore,
        predictor: CompositePredictor,
        stats: Statistics,
        on_show: Callable[[str, str, str], None],
        on_show_emoji: Callable[[str, list[tuple[str, str]]], None],
        on_hide: Callable[[], None],
    ):
        if keyboard is None:
            raise RuntimeError("pynput is required — pip install pynput")
        self.store = store
        self.predictor = predictor
        self.stats = stats
        self.on_show = on_show
        self.on_show_emoji = on_show_emoji
        self.on_hide = on_hide

        self.state = TypingState()
        self.controller = Controller()
        self.listener: Optional[keyboard.Listener] = None
        self._paused = False

        predictor.on_llm_result = self._on_llm_result

    # ---- lifecycle ----------------------------------------------------------

    def start(self) -> None:
        self.listener = keyboard.Listener(
            on_press=self._on_press,
            on_release=self._on_release,
        )
        self.listener.daemon = True
        self.listener.start()

    def stop(self) -> None:
        if self.listener:
            self.listener.stop()
            self.listener = None

    def toggle_paused(self) -> bool:
        self._paused = not self._paused
        if self._paused:
            self.on_hide()
        return self._paused

    # ---- event handling -----------------------------------------------------

    def _on_press(self, key) -> None:
        if self._paused:
            return
        if not self.store.app_enabled(_front_app_name()):
            return

        accept_full = self._matches(key, self.store.config.accept_full_key)
        accept_word = self._matches(key, self.store.config.accept_word_key)

        if self.state.in_emoji and accept_full:
            self._commit_emoji()
            return
        if self.state.last_suggestion and accept_full:
            self._commit_completion(full=True)
            return
        if self.state.last_suggestion and accept_word:
            self._commit_completion(full=False)
            return

        char = self._key_char(key)
        if char is None:
            if key == Key.space:
                self._flush_word()
                return
            if key == Key.backspace:
                self._handle_backspace()
                return
            if key in (Key.enter, Key.esc):
                self._flush_word()
                self.on_hide()
                return
            # punctuation / modifier / arrows etc.
            self._flush_word()
            self.on_hide()
            return

        if char == ":" and self.store.config.enable_emoji_suggestions:
            self.state.in_emoji = True
            self.state.emoji_query = ""
            self.on_show(":", "", "Tab ⇥")
            return

        if self.state.in_emoji:
            if WORD_CHARS.match(char) or char == "_":
                self.state.emoji_query += char
                matches = match_emojis(self.state.emoji_query)
                if matches:
                    self.on_show_emoji(":" + self.state.emoji_query, matches)
                else:
                    self.on_hide()
                return
            self.state.reset_emoji()
            self.on_hide()

        if WORD_CHARS.match(char):
            self.state.current_word += char
            self._predict()
            return

        self._flush_word()
        self.on_hide()

    def _on_release(self, _key) -> None:
        return

    def _handle_backspace(self) -> None:
        if self.state.in_emoji:
            if self.state.emoji_query:
                self.state.emoji_query = self.state.emoji_query[:-1]
                matches = match_emojis(self.state.emoji_query)
                if matches:
                    self.on_show_emoji(":" + self.state.emoji_query, matches)
                    return
            self.state.reset_emoji()
            self.on_hide()
            return
        if self.state.current_word:
            self.state.current_word = self.state.current_word[:-1]
            if self.state.current_word:
                self._predict()
            else:
                self.state.last_suggestion = None
                self.on_hide()
            return
        self.on_hide()

    def _flush_word(self) -> None:
        if self.state.current_word:
            self.state.push_word(self.state.current_word)
            self.predictor.ngram.learn(self.state.context[-3:])
            self.state.current_word = ""
        self.state.last_suggestion = None

    def _predict(self) -> None:
        word = self.state.current_word
        fast = self.predictor.predict_fast(self.state.context, word)
        if fast and len(fast) > len(word):
            self.state.last_suggestion = fast
            self.on_show(word, fast, self._accept_hint())
        else:
            self.state.last_suggestion = None
            self.on_hide()
        self.predictor.request_llm(self.state.context, word)

    def _on_llm_result(self, prefix: str, suggestion: str) -> None:
        if prefix != self.state.current_word:
            return
        if not suggestion or len(suggestion) <= len(prefix):
            return
        self.state.last_suggestion = suggestion
        self.on_show(prefix, suggestion, self._accept_hint())

    def _accept_hint(self) -> str:
        return f"Tab ⇥   ·   `{self.store.config.accept_word_key}` word"

    # ---- completion injection ----------------------------------------------

    def _commit_completion(self, full: bool) -> None:
        suggestion = self.state.last_suggestion
        typed = self.state.current_word
        if not suggestion or not suggestion.lower().startswith(typed.lower()):
            return

        remaining_full = suggestion[len(typed):]
        if full:
            insertion = remaining_full
            if self.store.config.include_trailing_space:
                insertion += " "
        else:
            # single word: if suggestion is already one word, same as full;
            # if multi-word, take up to next space
            space_idx = remaining_full.find(" ")
            if space_idx == -1:
                insertion = remaining_full
            else:
                insertion = remaining_full[:space_idx]
            if self.store.config.include_trailing_space:
                insertion += " "

        def do_insert():
            # Delete the modifier key character that just got typed
            # (Tab / backtick) from the focused field.
            self.controller.press(Key.backspace)
            self.controller.release(Key.backspace)
            self.controller.type(insertion)

        threading.Timer(0.005, do_insert).start()

        if full:
            self.state.push_word(suggestion)
            self.state.current_word = ""
        else:
            accepted_word = insertion.strip()
            self.state.current_word = (typed + remaining_full[:len(insertion.strip()) - len(typed)]) if False else ""
            self.state.push_word(accepted_word)
        self.state.last_suggestion = None
        self.on_hide()
        self.stats.record(insertion.strip())
        self.stats.save()

    def _commit_emoji(self) -> None:
        matches = match_emojis(self.state.emoji_query)
        if not matches:
            self.state.reset_emoji()
            self.on_hide()
            return
        _, glyph = matches[0]
        typed_len = 1 + len(self.state.emoji_query)  # ':' + query
        def do_insert():
            self.controller.press(Key.backspace)
            self.controller.release(Key.backspace)
            for _ in range(typed_len):
                self.controller.press(Key.backspace)
                self.controller.release(Key.backspace)
            self.controller.type(glyph)
        threading.Timer(0.005, do_insert).start()
        self.state.reset_emoji()
        self.on_hide()

    # ---- helpers ------------------------------------------------------------

    @staticmethod
    def _key_char(key) -> Optional[str]:
        if isinstance(key, KeyCode) and key.char:
            return key.char
        return None

    @staticmethod
    def _matches(key, shortcut: str) -> bool:
        s = shortcut.lower()
        if s == "tab":
            return key == Key.tab
        if s in ("enter", "return"):
            return key == Key.enter
        if s in ("esc", "escape"):
            return key == Key.esc
        if s == "space":
            return key == Key.space
        if isinstance(key, KeyCode) and key.char:
            return key.char == shortcut
        return False
