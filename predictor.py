"""Prediction engine.

Two layers, combined:

1. NGramPredictor — instant bigram/trigram + dictionary-prefix completion.
   Zero-latency; runs on every keystroke. Learns from everything the user types.

2. LLMPredictor — Gemma 3n E2B via MLX (Apple Silicon).
   Higher-quality context-aware completions. Runs on a debounce so we
   don't burn cycles on every keystroke.

The CompositePredictor prefers the LLM when available, and always falls
back to the n-gram result so suggestions appear instantly.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
from collections import defaultdict
from pathlib import Path
from typing import Optional

from dictionary import load_dictionary

WORD_RE = re.compile(r"[A-Za-z']+")


# ---------------------------------------------------------------------------
# N-gram predictor
# ---------------------------------------------------------------------------

class NGramPredictor:
    def __init__(self, data_path: Path):
        self.data_path = data_path
        self.unigrams: dict[str, int] = defaultdict(int)
        self.bigrams: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
        self.trigrams: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
        self.dictionary, self.dict_weight = load_dictionary()
        self._lock = threading.Lock()
        self._dirty = False
        self.load()

    def load(self) -> None:
        if not self.data_path.exists():
            return
        try:
            with open(self.data_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            for w, c in data.get("unigrams", {}).items():
                self.unigrams[w] = c
            for prev, nxt in data.get("bigrams", {}).items():
                for w, c in nxt.items():
                    self.bigrams[prev][w] = c
            for prev, nxt in data.get("trigrams", {}).items():
                for w, c in nxt.items():
                    self.trigrams[prev][w] = c
        except (OSError, json.JSONDecodeError):
            pass

    def save(self) -> None:
        with self._lock:
            if not self._dirty:
                return
            data = {
                "unigrams": dict(self.unigrams),
                "bigrams": {k: dict(v) for k, v in self.bigrams.items()},
                "trigrams": {k: dict(v) for k, v in self.trigrams.items()},
            }
            self._dirty = False
        self.data_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.data_path.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.replace(tmp, self.data_path)

    def learn(self, words: list[str]) -> None:
        if not words:
            return
        with self._lock:
            for i, w in enumerate(words):
                self.unigrams[w] += 1
                if i >= 1:
                    self.bigrams[words[i - 1]][w] += 1
                if i >= 2:
                    key = f"{words[i - 2]} {words[i - 1]}"
                    self.trigrams[key][w] += 1
            self._dirty = True

    def predict(self, context: list[str], prefix: str) -> Optional[str]:
        if not prefix:
            return None
        prefix_l = prefix.lower()
        candidates: dict[str, float] = {}

        if len(context) >= 2:
            key = f"{context[-2]} {context[-1]}"
            for w, c in self.trigrams.get(key, {}).items():
                if w.startswith(prefix_l) and w != prefix_l:
                    candidates[w] = candidates.get(w, 0) + c * 400

        if len(context) >= 1:
            for w, c in self.bigrams.get(context[-1], {}).items():
                if w.startswith(prefix_l) and w != prefix_l:
                    candidates[w] = candidates.get(w, 0) + c * 120

        for w, c in self.unigrams.items():
            if w.startswith(prefix_l) and w != prefix_l:
                candidates[w] = candidates.get(w, 0) + c * 30

        for w in self.dictionary:
            if w.startswith(prefix_l) and w != prefix_l:
                base = self.dict_weight.get(w, 0)
                candidates[w] = candidates.get(w, 0) + base * 0.1 + 0.2

        if not candidates:
            return None
        best = max(candidates.items(), key=lambda kv: (kv[1], -len(kv[0])))[0]
        if prefix[0].isupper():
            best = best.capitalize()
        elif prefix.isupper() and len(prefix) > 1:
            best = best.upper()
        return best


# ---------------------------------------------------------------------------
# LLM predictor (Gemma 4 E2B via llama.cpp — same runtime Cotypist uses)
# ---------------------------------------------------------------------------


class LLMPredictor:
    """On-device LLM completion using Gemma 4 E2B through llama-cpp-python.

    Loaded lazily on a background thread so startup stays fast. If
    llama-cpp-python isn't installed or the GGUF can't be found, `available`
    stays False and the n-gram predictor carries the whole load.

    Tries `model_path` first, then `find_model_path()` — which searches
    SpeedoTyper's own Models directory and the path Cotypist uses, so an
    already-downloaded GGUF is reused automatically.
    """

    SYSTEM_PROMPT = (
        "You are an autocomplete engine. Given the user's in-progress "
        "sentence, continue it with the next few words the user is most "
        "likely to type. Match their register exactly. Reply with only "
        "the continuation text — no quotes, no explanation, no punctuation "
        "at the end."
    )

    def __init__(
        self,
        model_path: Optional[Path] = None,
        max_tokens: int = 8,
        n_ctx: int = 2048,
        n_gpu_layers: int = -1,
        custom_instructions: str = "",
    ):
        from config import find_model_path

        self.model_path = model_path or find_model_path()
        self.max_tokens = max_tokens
        self.n_ctx = n_ctx
        self.n_gpu_layers = n_gpu_layers
        self.custom_instructions = custom_instructions.strip()
        self.llm = None
        self.available = False
        self._load_error: Optional[str] = None
        self._lock = threading.Lock()
        threading.Thread(target=self._load, daemon=True).start()

    def _load(self) -> None:
        if not self.model_path:
            self._load_error = "no GGUF found (set SPEEDOTYPER_MODEL or install Cotypist)"
            return
        try:
            from llama_cpp import Llama, LlamaRAMCache  # type: ignore
        except ImportError as e:
            self._load_error = f"llama-cpp-python not installed ({e})"
            return
        try:
            self.llm = Llama(
                model_path=str(self.model_path),
                n_ctx=self.n_ctx,
                n_gpu_layers=self.n_gpu_layers,
                logits_all=False,
                verbose=False,
                # Keep the whole batch resident in the KV cache.
                n_batch=512,
                use_mmap=True,
                use_mlock=False,
            )
            # Prompt cache: reuses KV across calls whose prompts share a
            # prefix. The big win for autocomplete — as the user types one
            # character at a time, only the new tokens need to be prefilled.
            # 1 GiB is plenty of headroom for a 2 k context model.
            try:
                self.llm.set_cache(LlamaRAMCache(capacity_bytes=1 << 30))
            except Exception:
                pass
            self.available = True
        except Exception as e:
            self._load_error = f"failed to load {self.model_path.name}: {e}"

    def status(self) -> str:
        if self.available:
            return f"LLM ready: {self.model_path.name}"
        if self._load_error:
            return f"LLM unavailable ({self._load_error})"
        return "LLM loading..."

    def _system(self) -> str:
        if self.custom_instructions:
            return f"{self.SYSTEM_PROMPT}\n\nStyle guide:\n{self.custom_instructions}"
        return self.SYSTEM_PROMPT

    def _finalize(self, completion: str, prefix: str) -> Optional[str]:
        """Normalize a raw completion string into (prefix + continuation)."""
        completion = (completion or "").lstrip()
        if not completion:
            return None
        first = WORD_RE.search(completion)
        if not first:
            return None
        word = first.group(0).lower()
        if word == prefix.lower():
            return None
        if word.startswith(prefix.lower()):
            result = word
        else:
            combined = (prefix + word).lower()
            if combined.startswith(prefix.lower()) and len(combined) > len(prefix):
                result = combined
            else:
                return None
        if prefix[0].isupper():
            result = result.capitalize()
        elif prefix.isupper() and len(prefix) > 1:
            result = result.upper()
        return result

    def predict(self, context_text: str, prefix: str) -> Optional[str]:
        """Blocking, non-streaming predict. Kept for CLI / testing."""
        acc = []
        for chunk, is_final in self.predict_stream(context_text, prefix):
            acc.append(chunk)
            if is_final:
                break
        return self._finalize("".join(acc), prefix)

    def predict_stream(
        self,
        context_text: str,
        prefix: str,
        cancel_check=None,
    ):
        """Yield `(chunk_text, is_final)` tuples as the model streams.

        Consumers can call `_finalize("".join(chunks_so_far), prefix)` after
        any chunk to get the best current guess — useful for showing a
        suggestion as soon as the first word arrives instead of waiting
        for max_tokens to exhaust.
        """
        if not self.available or not prefix:
            return
        user = f"{context_text}{prefix}"
        messages = [
            {"role": "system", "content": self._system()},
            {"role": "user", "content": user},
        ]
        try:
            with self._lock:
                stream = self.llm.create_chat_completion(
                    messages=messages,
                    max_tokens=self.max_tokens,
                    temperature=0.15,
                    top_p=0.9,
                    stop=["\n", ". ", "! ", "? "],
                    stream=True,
                )
                for chunk in stream:
                    if cancel_check and cancel_check():
                        return
                    try:
                        delta = chunk["choices"][0]["delta"].get("content", "")
                        is_final = chunk["choices"][0].get("finish_reason") is not None
                    except (KeyError, IndexError, TypeError):
                        continue
                    if delta:
                        yield delta, is_final
                    elif is_final:
                        yield "", True
                        return
        except Exception:
            return


# ---------------------------------------------------------------------------
# Composite
# ---------------------------------------------------------------------------

class CompositePredictor:
    """N-gram for instant suggestions, LLM refinement via streaming.

    `predict_fast` runs on every keystroke and always returns immediately.
    `request_llm` asks the LLM for a better suggestion; as the LLM streams,
    `on_llm_result(prefix, suggestion)` is fired as soon as the first word
    becomes available, and again with a better suggestion if more words
    arrive before the stream ends or gets cancelled.

    A newer `request_llm` call cancels any in-flight stream — the cost of a
    stale keystroke is ~one extra decoded token, not a full generation.
    """

    def __init__(
        self,
        ngram: NGramPredictor,
        llm: Optional[LLMPredictor] = None,
        debounce_seconds: float = 0.04,
        on_llm_result=None,
    ):
        self.ngram = ngram
        self.llm = llm
        self.debounce = debounce_seconds
        self.on_llm_result = on_llm_result
        self._pending_token = 0
        self._worker_lock = threading.Lock()
        # Optional wall-clock logging for perf tuning. Set SPEEDOTYPER_PROFILE=1.
        import os as _os
        self._profile = bool(_os.environ.get("SPEEDOTYPER_PROFILE"))

    def predict_fast(self, context: list[str], prefix: str) -> Optional[str]:
        return self.ngram.predict(context, prefix)

    def request_llm(self, context: list[str], prefix: str) -> None:
        if not self.llm or not self.llm.available:
            return
        self._pending_token += 1
        token = self._pending_token
        ctx_text = " ".join(context[-20:])
        if ctx_text:
            ctx_text += " "

        def cancelled() -> bool:
            return token != self._pending_token

        def run():
            # Small debounce keeps us from firing an LLM call on every
            # in-flight keystroke during a burst of typing.
            time.sleep(self.debounce)
            if cancelled():
                return

            buf_parts: list[str] = []
            last_emit: Optional[str] = None
            first_token_ms: Optional[float] = None
            start = time.perf_counter()

            try:
                for chunk, is_final in self.llm.predict_stream(
                    ctx_text, prefix, cancel_check=cancelled
                ):
                    if first_token_ms is None:
                        first_token_ms = (time.perf_counter() - start) * 1000
                    if chunk:
                        buf_parts.append(chunk)
                    candidate = self.llm._finalize("".join(buf_parts), prefix)
                    if candidate and candidate != last_emit and not cancelled():
                        last_emit = candidate
                        if self.on_llm_result:
                            self.on_llm_result(prefix, candidate)
                    if is_final:
                        break
            except Exception:
                return

            if self._profile and first_token_ms is not None:
                total = (time.perf_counter() - start) * 1000
                print(
                    f"[llm] prefix={prefix!r} first={first_token_ms:.0f}ms "
                    f"total={total:.0f}ms final={last_emit!r}"
                )

        threading.Thread(target=run, daemon=True).start()

    def cancel_llm(self) -> None:
        self._pending_token += 1
