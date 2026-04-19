"""SpeedoTyper — system-wide AI autocomplete for macOS.

Entry point. Wires together the keyboard engine, prediction engine,
overlay, and preferences window, and runs the Tk main loop.

Run:  python speedotyper.py
      python speedotyper.py --demo      # standalone text-editor demo
      python speedotyper.py --settings  # open settings without keyboard hook
"""

from __future__ import annotations

import argparse
import sys
import threading
import tkinter as tk
from pathlib import Path

from config import ConfigStore, Statistics, NGRAM_PATH, find_model_path
from predictor import NGramPredictor, LLMPredictor, CompositePredictor
from overlay import Overlay
from settings_window import SettingsWindow


def _check_accessibility() -> bool:
    """Return True if macOS Accessibility permission is granted."""
    if sys.platform != "darwin":
        return True
    try:
        from ApplicationServices import AXIsProcessTrusted  # type: ignore
        return bool(AXIsProcessTrusted())
    except Exception:
        return True


def _check_model_downloaded(model_id: str | None = None) -> bool:
    model_path = find_model_path()
    if model_path is None:
        return False
    if not model_id:
        return True
    return model_path.name == model_id


class App:
    def __init__(self, enable_keyboard: bool = True):
        self.store = ConfigStore()
        self.stats = Statistics()

        self.ngram = NGramPredictor(NGRAM_PATH)
        self.llm = LLMPredictor(
            n_ctx=self.store.config.n_ctx,
            n_gpu_layers=self.store.config.n_gpu_layers,
            custom_instructions=self.store.config.custom_instructions,
        ) if self.store.config.enable_llm else None
        self.predictor = CompositePredictor(self.ngram, self.llm)

        self.root = tk.Tk()
        self.root.withdraw()
        self.root.title("SpeedoTyper")

        self.overlay = Overlay(self.root)

        self.settings = SettingsWindow(
            self.root, self.store, self.stats,
            permissions_provider=self._permissions_snapshot,
        )

        self._engine = None
        if enable_keyboard:
            try:
                from keyboard_engine import KeyboardEngine
                self._engine = KeyboardEngine(
                    self.store, self.predictor, self.stats,
                    on_show=self.overlay.show,
                    on_show_emoji=self.overlay.show_emoji,
                    on_hide=self.overlay.hide,
                )
                self._engine.start()
            except RuntimeError as e:
                print(f"[SpeedoTyper] keyboard engine disabled: {e}")

        # Periodically persist learned n-grams.
        self._schedule_save()

    # ---- permissions & menubar ---------------------------------------------

    def _permissions_snapshot(self) -> dict:
        return {
            "accessibility": _check_accessibility(),
            "screen": False,
            "model": _check_model_downloaded(self.store.config.model_id),
        }

    def _schedule_save(self):
        def save():
            self.ngram.save()
            self.root.after(10_000, save)
        self.root.after(10_000, save)

    def run(self):
        self.settings.show()
        self.root.protocol("WM_DELETE_WINDOW", self._quit)
        self.root.mainloop()

    def _quit(self):
        if self._engine:
            self._engine.stop()
        self.ngram.save()
        self.stats.save()
        self.root.destroy()


def main():
    ap = argparse.ArgumentParser(prog="speedotyper")
    ap.add_argument("--demo", action="store_true",
                    help="Run a standalone text-editor demo (no global keyboard hook).")
    ap.add_argument("--settings", action="store_true",
                    help="Open settings window only; do not install keyboard hook.")
    args = ap.parse_args()

    if args.demo:
        from demo import run_demo
        run_demo()
        return

    app = App(enable_keyboard=not args.settings)
    app.run()


if __name__ == "__main__":
    main()
