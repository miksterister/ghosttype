# GhostType · ghosttype_server.py
# Custom local FIM (fill-in-the-middle) completion server. Replaces the stock
# mlx_lm.server: keeps a FIM-capable model resident and completes the gap between
# the text before the caret (prefix) and after it (suffix). Apple Silicon only.
import json
import os
import re
import threading
from contextlib import asynccontextmanager

from fastapi import FastAPI, Response
from pydantic import BaseModel
from mlx_lm import load, stream_generate
from mlx_lm.tokenizer_utils import BPEStreamingDetokenizer

# The ONE place the model is chosen (GHOSTTYPE_MODEL is a manual override only;
# the launchd plist deliberately sets no env). Must be FIM-trained on the
# <|fim_prefix|> tokens. Granite live trial since 2026-09-17; previous:
# mlx-community/Qwen2.5-Coder-1.5B-4bit.
MODEL = os.environ.get("GHOSTTYPE_MODEL", "mlx-community/granite-4.0-1b-base-4bit")

_state = {"model": None, "tok": None, "ready": False}
# mlx generate is blocking and not thread-safe; FastAPI runs sync endpoints in a
# threadpool, so serialize generation. Stale requests are cancelled client-side
# (the Lua client terminates the curl), so a queue of at most a couple is fine.
_gen_lock = threading.Lock()


def build_fim_prompt(prefix: str, suffix: str) -> str:
    """The Qwen2.5-Coder FIM control-token format. Pure; unit-tested."""
    return f"<|fim_prefix|>{prefix}<|fim_suffix|>{suffix}<|fim_middle|>"


def stop_at(text: str, max_words: int | None = None) -> str | None:
    """Early-stop decision over accumulated streamed text. Pure; unit-tested.
    Returns the final trimmed text once generation should stop, else None.
    Stops at the first control token (every Qwen special token starts with
    "<|" — <|fim_pad|>, <|endoftext|>, ... leak into prose FIM output when
    the model has nothing to say), at the first newline, or once max_words
    words are *completed* (a word is completed when whitespace follows it)."""
    ctl = text.find("<|")
    if ctl != -1:
        head = text[:ctl]
        trimmed = stop_at(head, max_words)
        return trimmed if trimmed is not None else head
    nl = text.find("\n")
    head = text[:nl] if nl != -1 else text
    if max_words:
        n = 0
        for m in re.finditer(r"\S+", head):
            done = m.end() < len(head) and head[m.end()].isspace()
            if done or nl != -1:
                n += 1
                if n == max_words:
                    return head[: m.end()]
    return head if nl != -1 else None


_WORD = re.compile(r"[^\W_]+(?:'[^\W_]+)?", re.UNICODE)


def trim_suffix_echo(text: str, suffix: str) -> str:
    """Cut the suggestion where it starts repeating the text right of the caret.
    Pure; unit-tested. FIM models often "fill" the gap with the suffix itself
    ("The capital of France|" + " is Paris." → "is Paris. The capital"), which
    would duplicate it on accept. Word-level, case/punctuation-insensitive; the
    overlap must run to the end of the suggestion or cover the whole suffix."""
    sw = [w.lower() for w in _WORD.findall(suffix.split("\n", 1)[0])]
    if not sw:
        return text
    words = list(_WORD.finditer(text))
    tw = [m.group().lower() for m in words]
    for i in range(len(tw)):
        k = min(len(tw) - i, len(sw))
        if tw[i:i + k] == sw[:k]:
            return text[: words[i].start()].rstrip()
    return text


def has_content(text: str) -> bool:
    """A suggestion with no letter or digit in it is never worth showing.
    Pure; unit-tested. Live log entries this kills: ".", "?", ")", and
    ":(:(:(:(:(:(:(:(" — pure punctuation the base model emits when it has
    nothing to say. Deliberately NOT a length or repetition rule: "e." is a
    real mid-word completion of "sourc|e." and must survive."""
    return any(ch.isalnum() for ch in text)


class _KeepLeadingSpace(BPEStreamingDetokenizer):
    """mlx-lm drops the first token's leading space ("Ġat" → "at") — right for
    a chat reply, wrong for FIM: after "we should meet|" the model DID emit the
    separator, and dropping it glued "meetat" onto the caret. Keep it; the
    prefix decides in finish() whether it is redundant."""

    def _maybe_trim_space(self, text):
        return text if not self.text else super()._maybe_trim_space(text)


def finish(text: str, prefix: str, suffix: str) -> str:
    """Final suggestion from generated text. Pure; unit-tested. The model's
    leading space is the word separator, so it survives unless the user
    already typed one ("meet |" + " at" would double-space)."""
    out = trim_suffix_echo(text, suffix)
    if prefix[-1:].isspace():
        out = out.lstrip()
    return out if has_content(out) else ""


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Eager-load so the first real request is warm (ghostwriter's lesson).
    model, tok = load(MODEL)
    # ponytail: BPE only (Granite, Qwen2.5-Coder); an SPM model would need
    # partial(SPMStreamingDetokenizer, trim_space=False) here instead.
    if tok._detokenizer_class is BPEStreamingDetokenizer:
        tok._detokenizer_class = _KeepLeadingSpace
    _state["model"], _state["tok"], _state["ready"] = model, tok, True
    yield


app = FastAPI(lifespan=lifespan)


class CompleteReq(BaseModel):
    prefix: str = ""
    suffix: str = ""
    max_tokens: int = 8
    max_words: int | None = None


# The master on/off toggle lives in the Hammerspoon config (menubar / ⌘⌥G both
# write it). Gating here means EVERY client — Hammerspoon overlay, Obsidian
# plugin, anything future — respects the toggle without its own logic.
CONFIG_PATH = os.path.expanduser("~/.config/ghosttype/config.json")


def _enabled() -> bool:
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f).get("enabled", True)
    except Exception:
        return True  # missing/corrupt config never turns completions off


# Session tally for clients that can't reach the Hammerspoon menubar directly
# (the Obsidian plugin POSTs its outcomes here; the menubar reads /stats when
# opened). In-memory on purpose — same lifetime as the menubar's own tally.
_events = {"shown": 0, "accepted": 0, "dismissed": 0}


class EventReq(BaseModel):
    kind: str = ""


@app.get("/ready")
def ready():
    # 200 only once the model is actually loaded — a precise signal the client
    # polls, unlike mlx_lm.server's /v1/models which can answer before load.
    return Response(status_code=200 if _state["ready"] else 503)


@app.get("/model")
def model():
    return {"model": MODEL}  # what is actually loaded; Settings shows this


@app.post("/event")
def event(req: EventReq):
    if req.kind in _events:
        _events[req.kind] += 1
    return {"ok": True}


@app.get("/stats")
def stats():
    return _events


@app.post("/complete")
def complete(req: CompleteReq):
    if not _state["ready"] or not _enabled():
        return {"text": ""}
    prompt = build_fim_prompt(req.prefix, req.suffix)
    text = ""
    with _gen_lock:
        # Stream so we can stop at the first newline / word cap instead of
        # paying for max_tokens the clients would discard anyway. If no stop
        # condition fires, the accumulated text is returned unchanged —
        # today's max-token behavior.
        gen = stream_generate(
            _state["model"], _state["tok"],
            prompt=prompt, max_tokens=req.max_tokens,
        )
        try:
            for resp in gen:
                text += resp.text
                stopped = stop_at(text, req.max_words)
                if stopped is not None:
                    return {"text": finish(stopped, req.prefix, req.suffix)}
        finally:
            # Early return abandons the generator; close it here so mlx's
            # wired-limit teardown runs inside _gen_lock, not at GC time.
            gen.close()
    return {"text": finish(text, req.prefix, req.suffix)}
