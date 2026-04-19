# SpeedoTyper (Swift)

Native macOS port of [SpeedoTyper](../README.md) — the Cotypist-inspired
system-wide AI autocomplete. This subdirectory holds the real target: Swift +
AppKit + SwiftUI, matching Cotypist's stack. The original Python code at the
repo root remains as a reference implementation for the prediction logic.

## Status

This is a working skeleton:

| Piece                          | Status   |
|--------------------------------|----------|
| NSPanel overlay + SwiftUI view | ✅       |
| CGEventTap global listener     | ✅       |
| Word + context tracking        | ✅       |
| Tab / backtick accept          | ✅       |
| Unicode text injection         | ✅       |
| N-gram predictor (trigram/bigram/unigram + system dictionary) | ✅ |
| Persisted learning (`ngrams.json`) | ✅   |
| Accessibility caret tracking   | ✅       |
| Menu bar status item           | ✅       |
| LLM (Gemma 4 E2B via llama.cpp) | ⏳ stubbed — next pass |
| Settings window (9 panels)     | ⏳ next pass |
| Emoji shortcodes               | ⏳ next pass |
| Screen-recording context       | ⏳ next pass |

## Build & run

```bash
cd SpeedoTyperMac
swift build -c release
.build/release/SpeedoTyper
```

On first run macOS will prompt for **Accessibility** permission
(*System Settings → Privacy & Security → Accessibility*). Approve the
`SpeedoTyper` binary and relaunch. Because `swift run` launches through your
terminal, you may also need to grant Accessibility to your terminal emulator.

To open in Xcode:

```bash
open Package.swift
```

## Architecture

```
SpeedoTyper
├── main.swift                      — NSApplication entry
├── AppDelegate.swift               — wiring, status item, AX check
├── Overlay/
│   ├── OverlayController.swift     — floating NSPanel + caret tracking
│   └── OverlayView.swift           — SwiftUI pill (typed + ghost + hint)
├── Keyboard/
│   ├── EventTap.swift              — CGEventTap wrapper
│   ├── Injector.swift              — unicode key-event synthesis
│   └── KeyboardEngine.swift        — word tracking, Tab accept, debounce
├── Prediction/
│   ├── Predictor.swift             — protocol
│   ├── NGramPredictor.swift        — 400/120/30/0.1-weighted completion
│   └── CompositePredictor.swift    — n-gram → LLM layering
└── Config/
    └── ConfigStore.swift           — JSON-backed prefs, model resolution
```

Data lives under `~/Library/Application Support/SpeedoTyper/`:
- `config.json` — preferences
- `ngrams.json` — learned n-grams (persisted every 10 s)
- `Models/gemma-4-E2B-i1-Q4_K_M.gguf` — LLM weights (or reuses Cotypist's)

## LLM integration plan

Cotypist links `libllama.0.dylib` + `libggml-metal.0.dylib` directly. The Swift
port will do the same via a `llama.xcframework`:

1. Build llama.cpp with Metal and `BUILD_SHARED_LIBS=ON`.
2. Wrap the resulting dylibs in a binary `.xcframework`.
3. Add a `systemLibrary` or `binaryTarget` entry to `Package.swift` with a
   module map exposing the C symbols.
4. Implement `LLMPredictor.swift` mirroring
   [`predictor.py`](../predictor.py)'s `LLMPredictor` — KV-cache reuse,
   streaming via `llama_decode`, cancellation via generation tokens.

Until that lands, `CompositePredictor` runs n-gram-only and the overlay still
shows sub-millisecond suggestions.

## Known gaps vs Cotypist

- No Xcode project yet; SwiftPM executable only. Dock icon / Info.plist
  bundling will come with a proper app target.
- No code signing / notarization. Dev builds are unsigned.
- Tab interception relies on the event tap swallowing the keystroke; we don't
  currently re-send backspace if the Tab leaked through.
- Hotkey customization lives in `Config` but isn't wired to the listener yet
  (engine hardcodes Tab / backtick / Escape).
