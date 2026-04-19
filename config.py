"""Configuration + statistics persistence.

Stored as JSON under ~/Library/Application Support/SpeedoTyper/ on macOS,
or ~/.speedotyper/ elsewhere.
"""

from __future__ import annotations

import json
import os
import sys
import threading
from dataclasses import dataclass, field, asdict
from datetime import date
from pathlib import Path
from typing import Optional  # noqa: F401 — used below after dataclass defs


def _default_base_dir() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "SpeedoTyper"
    return Path.home() / ".speedotyper"


BASE_DIR = Path(os.environ.get("SPEEDOTYPER_HOME", _default_base_dir()))
CONFIG_PATH = BASE_DIR / "config.json"
STATS_PATH = BASE_DIR / "stats.json"
NGRAM_PATH = BASE_DIR / "ngrams.json"

# Candidate locations for a pre-downloaded Gemma GGUF. We probe these in order
# before falling back to auto-download. Lets us reuse the file Cotypist already
# pulled.
GGUF_CANDIDATES = [
    Path(os.environ.get("SPEEDOTYPER_MODEL", "/dev/null")),
    BASE_DIR / "Models" / "gemma-4-E2B-i1-Q4_K_M.gguf",
    Path.home() / "Library" / "Application Support" / "app.cotypist.Cotypist"
        / "Models" / "gemma-4-E2B-i1-Q4_K_M.gguf",
]


def find_model_path() -> Optional[Path]:
    for p in GGUF_CANDIDATES:
        try:
            if p and p.is_file():
                return p
        except OSError:
            continue
    return None


DEFAULT_INSTRUCTIONS = (
    "Write in a friendly, professional and empathetic voice. "
    "Keep sentences short, concise and readable."
)


@dataclass
class Config:
    # General
    launch_at_login: bool = False
    show_status_item: bool = True
    show_accessory_button: bool = False

    # AI — mirrors Cotypist: Gemma 4 E2B as GGUF via llama.cpp.
    model_id: str = "gemma-4-E2B-i1-Q4_K_M.gguf"
    model_label: str = "Gemma 4 E2B (3.2 GB)"
    enable_llm: bool = True
    n_ctx: int = 2048
    n_gpu_layers: int = -1  # -1 = offload all layers to Metal
    enable_completions: bool = True
    max_completion_length: str = "medium"  # short | medium | long

    # Context
    use_screenshot_context: bool = False
    improve_suggestion_positioning: bool = False
    use_clipboard_context: bool = True

    # Personalization
    collect_inputs: bool = False
    store_without_accepted: bool = True
    personalize_weight: float = 0.4  # 0..1
    custom_instructions: str = DEFAULT_INSTRUCTIONS

    # Emoji
    enable_emoji_suggestions: bool = True

    # Shortcuts (pynput key names)
    accept_full_key: str = "tab"
    accept_word_key: str = "`"
    force_activate_key: str = "ctrl+space"
    toggle_current_app_key: str = "ctrl+alt+cmd+t"
    toggle_global_key: str = "ctrl+alt+cmd+g"
    include_trailing_space: bool = True

    # Per-app
    app_overrides: dict = field(default_factory=dict)  # app_name -> {enabled: bool}

    # System
    macos_text_suggestions_disabled: bool = False


class ConfigStore:
    def __init__(self, path: Path = CONFIG_PATH):
        self.path = path
        self._lock = threading.Lock()
        self.config = Config()
        self.load()

    def load(self) -> None:
        if not self.path.exists():
            return
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                raw = json.load(f)
            for k, v in raw.items():
                if hasattr(self.config, k):
                    setattr(self.config, k, v)
        except (OSError, json.JSONDecodeError):
            pass

    def save(self) -> None:
        with self._lock:
            data = asdict(self.config)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, self.path)

    def update(self, **kwargs) -> None:
        with self._lock:
            for k, v in kwargs.items():
                if hasattr(self.config, k):
                    setattr(self.config, k, v)
        self.save()

    def app_enabled(self, app_name: Optional[str]) -> bool:
        if not self.config.enable_completions:
            return False
        if not app_name:
            return True
        ov = self.config.app_overrides.get(app_name)
        if ov is None:
            return True
        return bool(ov.get("enabled", True))


@dataclass
class DayStats:
    completions: int = 0
    words: int = 0
    characters: int = 0


class Statistics:
    def __init__(self, path: Path = STATS_PATH):
        self.path = path
        self._lock = threading.Lock()
        self.by_day: dict[str, DayStats] = {}
        self.load()

    def load(self) -> None:
        if not self.path.exists():
            return
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                raw = json.load(f)
            for day, v in raw.get("by_day", {}).items():
                self.by_day[day] = DayStats(**v)
        except (OSError, json.JSONDecodeError):
            pass

    def save(self) -> None:
        with self._lock:
            data = {
                "by_day": {k: asdict(v) for k, v in self.by_day.items()},
            }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, self.path)

    def record(self, completion: str) -> None:
        today = date.today().isoformat()
        with self._lock:
            d = self.by_day.setdefault(today, DayStats())
            d.completions += 1
            d.words += max(1, len(completion.split()))
            d.characters += len(completion)

    def today(self) -> DayStats:
        return self.by_day.get(date.today().isoformat(), DayStats())

    def recent(self, days: int = 30) -> list[tuple[str, DayStats]]:
        keys = sorted(self.by_day.keys())[-days:]
        return [(k, self.by_day[k]) for k in keys]

    def total(self) -> DayStats:
        t = DayStats()
        for v in self.by_day.values():
            t.completions += v.completions
            t.words += v.words
            t.characters += v.characters
        return t
