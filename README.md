# SpeedoTyper

A system-wide AI autocomplete for macOS, inspired by [Cotypist](https://cotypist.app/).
Ghost-text suggestions appear as you type in any app; Tab accepts, backtick
takes only the next word, and `:name` expands an emoji.

Offline-first: runs **Gemma 4 E2B** on-device via **llama.cpp + Metal** (the same
runtime Cotypist uses), with a zero-latency n-gram fallback that learns as you
type.

## Features

- **Inline suggestions** across macOS apps (Mail, Safari, Notes, Messages…)
- **Gemma 4 E2B** on-device completions — no data leaves your Mac
- **N-gram fallback** (trigram + bigram + dictionary) for instant, zero-latency
  predictions while the LLM warms up
- **Emoji shortcodes** — type `:heart`, `:fire`, `:tada` and press Tab
- **Per-app overrides** — disable SpeedoTyper inside specific apps
- **Statistics** — daily completion counts and 30-day chart
- **Custom AI instructions** for style
- **Preferences window** with the familiar sidebar layout
- **Standalone demo mode** — play with it in a built-in text editor
  without granting Accessibility permission

## Requirements

- macOS 14 or later (Apple Silicon recommended)
- Python 3.10+ with Tk 8.6 (the stock `/usr/local/bin/python3` works; avoid
  Python 3.14+ from Homebrew, which lacks Tk)
- ~3.5 GB free disk for the 4-bit Gemma 4 E2B model (downloaded on first run)

## Install

```bash
cd /Users/samson/Desktop/Python/SpeedoTyper
python3 -m venv .venv
source .venv/bin/activate

# On Apple Silicon, build llama-cpp-python with Metal:
CMAKE_ARGS="-DGGML_METAL=on" pip install --upgrade --force-reinstall \
    --no-cache-dir llama-cpp-python

pip install -r requirements.txt
```

### Bring your own model (or reuse Cotypist's)

SpeedoTyper auto-discovers the Gemma 4 E2B GGUF in this order:

1. `$SPEEDOTYPER_MODEL` — absolute path you set yourself
2. `~/Library/Application Support/SpeedoTyper/Models/gemma-4-E2B-i1-Q4_K_M.gguf`
3. **Cotypist's copy**: `~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-4-E2B-i1-Q4_K_M.gguf`

If you already have Cotypist installed, you're done — SpeedoTyper will reuse
that 3.5 GB file instead of downloading another copy. Otherwise grab the GGUF
from HuggingFace (`unsloth/gemma-4-E2B-it-GGUF` or `bartowski/google_gemma-4-E2B-it-GGUF`)
and drop it at path #2.

On non-Apple-Silicon machines, llama.cpp builds CPU-only — the app still
works, just slower.

## Run

**Full system-wide mode** (grant Accessibility permission when prompted):

```bash
python3 speedotyper.py
```

On first launch macOS will ask for permission under
*System Settings → Privacy & Security → Accessibility*. Approve the Python
(or Terminal) process, then re-run.

**Standalone demo** — inline ghost text inside a built-in editor, no
permissions needed:

```bash
python3 speedotyper.py --demo
```

**Settings only** (no keyboard hook):

```bash
python3 speedotyper.py --settings
```

## Shortcuts

| Key          | Action                                   |
|--------------|------------------------------------------|
| `Tab`        | Accept the full suggestion               |
| `` ` ``      | Accept only the next word                |
| `Esc`        | Dismiss the suggestion                   |
| `:` + name   | Start an emoji suggestion                |
| `:` (again)  | Commit the first emoji match             |

All shortcuts are rebindable in the Shortcuts panel.

## How it works

- `predictor.py` — hybrid predictor:
  - `NGramPredictor`: unigram/bigram/trigram counts + macOS system dictionary
  - `LLMPredictor`: Gemma 4 E2B through `llama-cpp-python` with Metal offload
    (`n_gpu_layers=-1`), loaded lazily on a background thread
  - `CompositePredictor`: serves the n-gram result instantly and fires a
    debounced LLM request whose result replaces the ghost text if it beats
    the n-gram
- `keyboard_engine.py` — `pynput` listener tracks the current word and
  rolling 12-word context; `pynput.Controller` injects completions
- `overlay.py` — Tk `Toplevel` with transparent background and a pill-style
  hint, positioned near the cursor
- `settings_window.py` — sidebar + detail panel UI (Setup, General, Context,
  Personalization, Emoji, Shortcuts, App Settings, Statistics, About)
- `config.py` — JSON-backed config and per-day statistics in
  `~/Library/Application Support/SpeedoTyper/`

## Known limitations vs. Cotypist

- **Caret tracking is best-effort.** When pyobjc is installed and the focused
  app exposes `AXBoundsForRange`, the overlay sits at the actual caret; for
  apps that don't (some Electron / Chromium views), it falls back to the
  mouse position.
- **No screen-recording context yet.** Cotypist uses `ScreenCaptureKit` +
  `Vision`; wiring those up via pyobjc is the next improvement.
- **Accept-shortcut injection deletes one character** (the Tab / backtick the
  app captured before our handler fired). Most apps absorb this cleanly;
  terminals may show a brief flicker.
- **No imatrix quantization support in the n-gram** — that's the LLM side.
  The n-gram is a statistical model; learning just needs writing.

## Notes

- The n-gram model persists to `~/Library/Application Support/SpeedoTyper/ngrams.json`
  every 10 seconds while the app is running.
- To reset personalization, quit the app and delete the file above.
- To switch models, edit `model_id` in `config.json` in the same directory.
