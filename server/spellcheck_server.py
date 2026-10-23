# GhostType · spellcheck_server.py
# Sentence-level spelling/grammar CHECKING. It reports issues with character
# offsets and a suggested replacement; it never decides for the user. The client
# shows them and the user picks — the Grammarly/LanguageTool contract, not
# autocorrect. That choice also changes the engineering tradeoff: a false
# positive is a suggestion you ignore, not damage to your text, so recall is
# worth more here than the last few points of precision.
#
# Separate process from the FIM server on 8790 on purpose: this backend is
# either torch/CPU or an Ollama round-trip, and neither should contend with
# ghosttype_server's _gen_lock.
#
# Backends (GHOSTTYPE_SPELL_BACKEND), both measured on 86 sentences of the
# author's own notes + 14 German + 8 planted errors, idle M5 Pro (2026-08-23/24):
#   ollama  gemma4:e4b-mlx  294 ms/sentence  8/8 planted  0/14 German  ~8.8GB
#   encoder LFM2.5-350M     452 ms/sentence  7/8 planted  0/14 German  ~1.9GB
# gemma4-mlx is both faster and more accurate; the encoder stays as the
# small-footprint option for when RAM is tight. Only the encoder skips German
# (see skip_sentence).
#
# The Ollama backend MUST send think=false. gemma4:e4b is a thinking model, and
# through /api/generate its reasoning is discarded — measured 13.9s and a WORSE
# answer with thinking on, 0.4s with it off.
import json
import os
import re
import threading
import time
from contextlib import asynccontextmanager

import requests
from fastapi import FastAPI, Response
from pydantic import BaseModel

BACKEND = os.environ.get("GHOSTTYPE_SPELL_BACKEND", "ollama").lower()
OLLAMA_MODEL = os.environ.get("GHOSTTYPE_SPELL_OLLAMA_MODEL", "gemma4:e4b-mlx")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
ENCODER_MODEL = os.environ.get("GHOSTTYPE_SPELL_MODEL", "LiquidAI/LFM2.5-Encoder-350M-Spellchecker")
MIN_ERROR_PROB = float(os.environ.get("GHOSTTYPE_SPELL_MIN_ERROR_PROB", "0.7"))
MAX_ITER = int(os.environ.get("GHOSTTYPE_SPELL_MAX_ITER", "3"))
DIALECT = os.environ.get("GHOSTTYPE_SPELL_DIALECT", "british").lower()
MAX_LEN = 128          # the encoder truncates hard past this; see split_sentences

_state = {"correct": None, "ready": False}
_lock = threading.Lock()

PROMPT = ("Correct only spelling and grammar errors in the sentence below.\n"
          "Keep the original language and the author's wording. Do not rephrase, "
          "translate, shorten or explain.\n"
          "If the sentence is already correct, repeat it exactly.\n"
          "Output only the corrected sentence.\n\nSentence: {s}\nCorrected:")


# ---------------------------------------------------------------------------
# Tokenization contract for the encoder backend. It is trained on spaCy-style
# text — punctuation spaced out AND contractions split ("let's" -> "let 's").
# Feeding joined contractions is out-of-distribution and makes it edit them
# erratically. Pure; unit-tested.
# ---------------------------------------------------------------------------
_PUNCT = re.compile(r'([.,!?;:()\[\]{}"«»…])')
_ATTACH_LEFT = re.compile(r'\s+([.,!?;:%)\]}»…])')
_ATTACH_RIGHT = re.compile(r'([(\[{«])\s+')
_NT = re.compile(r"(\w+?)(n['’]t)\b", re.I)
_CONTR = re.compile(r"(\w)(['’](?:s|re|ve|ll|d|m))\b", re.I)
_REJOIN_NT = re.compile(r"\s+(n['’]t)\b", re.I)
_REJOIN_CONTR = re.compile(r"\s+(['’](?:s|re|ve|ll|d|m))\b", re.I)
_REJOIN_SPLIT_APOS = re.compile(r"(?<=\w)\s+(['’])\s+(?=(?:s|t|d|m|re|ve|ll)\b)", re.I)


def tokenize(text: str) -> str:
    text = _PUNCT.sub(r" \1 ", text)
    text = _NT.sub(r"\1 \2", text)
    text = _CONTR.sub(r"\1 \2", text)
    return re.sub(r"\s+", " ", text).strip()


def detok(text: str) -> str:
    text = _ATTACH_LEFT.sub(r"\1", text)
    text = _ATTACH_RIGHT.sub(r"\1", text)
    text = _REJOIN_NT.sub(r"\1", text)
    text = _REJOIN_CONTR.sub(r"\1", text)
    text = _REJOIN_SPLIT_APOS.sub(r"\1", text)
    return re.sub(r"\s+", " ", text).strip()


# ---------------------------------------------------------------------------
# split_sentences — chunks INCLUDE trailing whitespace, so "".join(chunks)
# reconstructs the input byte for byte. That is what lets us check sentence by
# sentence and still report offsets into the original text. Pure; unit-tested.
# ---------------------------------------------------------------------------
_SENT = re.compile(r"[^.!?]*[.!?]+\s*|[^.!?]+$")


def split_sentences(text: str) -> list[str]:
    return _SENT.findall(text)


# ---------------------------------------------------------------------------
# looks_german — every backend here is English-trained. Both scored 0 edits on
# 14 German sentences, so this gate is belt-and-braces; it exists because a bad
# German suggestion is noise the user has to read, and silence costs nothing.
# Deliberately biased toward false positives. Pure; unit-tested.
# ---------------------------------------------------------------------------
_DE_CHARS = re.compile(r"[äöüßÄÖÜ]")
# German-only function words. Words that are also English (die, man, er, es,
# sie, ein) are excluded — "The man will die" must not read as German.
_DE_WORDS = re.compile(
    r"\b(und|nicht|ist|sind|dass|auch|für|von|den|dem|der|das|zu|mit|sich|"
    r"aber|noch|wenn|kann|wird|werden|ich|wir|eine|einen|über|nach)\b", re.I)


def looks_german(text: str) -> bool:
    if _DE_CHARS.search(text):
        return True
    return len(set(w.lower() for w in _DE_WORDS.findall(text))) >= 2


def skip_sentence(core: str) -> bool:
    """Only the encoder is English-only. gemma4 through Ollama fixed 5/5
    planted German errors without translating (measured 2026-10-08), so the
    gate would cost a whole language there for nothing."""
    return BACKEND == "encoder" and looks_german(core)


# Markdown line syntax is not prose. Raw-markdown apps (Obsidian, Typora) send
# "> [!toggle]+ Companies try" and the model "fixes" the marker; stripping it
# server-side keeps both clients honest. The returned length rebases offsets.
_MD_PREFIX = re.compile(r"^\s*(?:>\s*)*(?:\[![^\]]*\][+-]?\s*)?(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+)?")


def strip_markdown_prefix(text: str) -> tuple[int, str]:
    n = _MD_PREFIX.match(text).end()
    return n, text[n:]


def plan_sentences(text: str) -> tuple[list[tuple[int, str]], list[str]]:
    """(offset, sentence) pairs to check, plus the skip reasons. The markdown
    prefix comes off BEFORE splitting: the "!" in "[!toggle]" is a sentence
    terminator, so splitting first made "> [!" its own sentence."""
    todo, skipped, offset = [], [], 0
    for line in text.splitlines(keepends=True):   # a selection can span lines
        lead, body = strip_markdown_prefix(line)
        pos = offset + lead
        for chunk in split_sentences(body):
            core = chunk.rstrip()
            if core and not skip_sentence(core):
                todo.append((pos, core))
            elif core:
                skipped.append("german")
            pos += len(chunk)
        offset += len(line)
    return todo, skipped


# ---------------------------------------------------------------------------
# Noise filters. Both backends were measured making two kinds of edit that are
# not errors, and in suggest-mode every one of these would be a line the user
# has to read and reject.
#
#   dialect  — trained on BEA/CoNLL, so they Americanize: analyse -> analyze,
#              recognise -> recognize, harbouring -> harboring.
#   cosmetic — gemma4 normalizes typographic punctuation: don’t -> don't.
#              Obsidian and macOS produce curly quotes; rewriting them is churn.
# Pure; unit-tested.
# ---------------------------------------------------------------------------
_ISE = re.compile(r"(is)(ation|ations|e|es|ed|ing)$")
_YSE = re.compile(r"(ys)(e|es|ed|ing)$")
_OUR = re.compile(r"our(s?)$")
_TRE = re.compile(r"tre(s?)$")
_COSMETIC = str.maketrans({"’": "'", "‘": "'", "‚": "'", "“": '"', "”": '"', "„": '"',
                           "«": '"', "»": '"', "–": "-", "—": "-", "…": "..."})


def to_american(word: str) -> str:
    w = word.lower()
    w = _ISE.sub(lambda m: "iz" + m.group(2), w)
    w = _YSE.sub(lambda m: "yz" + m.group(2), w)
    if len(w) >= 6:                       # keeps "four"/"tour" out of the our rule
        w = _OUR.sub(lambda m: "or" + m.group(1), w)
    if len(w) >= 5:
        w = _TRE.sub(lambda m: "ter" + m.group(1), w)
    return w


def _drop_one_s(w: str) -> str:
    return w[:-1] if w.endswith("s") else w


def is_dialect_only(old: str, new: str) -> bool:
    """True when the only difference is British -> American spelling."""
    if DIALECT != "british":
        return False
    if len(old.split()) != 1 or len(new.split()) != 1:
        return False                      # multi-word spans are real edits
    o, n = old.lower(), new.lower()
    a = to_american(o)
    if a == o:
        # The original has no American form, so whatever changed is grammar:
        # "strike" -> "strikes", "i" -> "I". Until 2026-10-08 this compared
        # to_american() of BOTH sides, which lowercases and (below) drops a
        # plural s, so every case-only and number-only fix was swallowed.
        return False
    # The number wobble is deliberate: "analyses" -> "analyze" is a dialect
    # rewrite wearing a plural. "analyses" -> "analysis" survives, as it should.
    return a == n or _drop_one_s(a) == _drop_one_s(n)


def is_cosmetic(old: str, new: str) -> bool:
    """True when the only difference is quote/dash typography — or ß vs ss:
    Swiss German has no ß, and gemma4 rewrites Strasse/gross on every line."""
    return old.translate(_COSMETIC).replace("ß", "ss") == new.translate(_COSMETIC).replace("ß", "ss")


_EDGE_PUNCT = ".,!?;:()[]{}\"«»…"


def _pair_ignorable(old: str, new: str) -> bool:
    if is_cosmetic(old, new):
        return True
    # Edge punctuation has to come off first: the dialect patterns are anchored
    # at the end of the word, so "colour." vs "color." missed entirely until
    # the full stop was stripped. Quotes are NOT stripped — is_cosmetic is the
    # one that needs to see them.
    return is_dialect_only(old.strip(_EDGE_PUNCT), new.strip(_EDGE_PUNCT))


def should_ignore(old: str, new: str) -> bool:
    """A diff span is noise only if EVERY word in it is noise. Spans of more
    than one word reach here whenever adjacent edits merge — "don’t organise"
    -> "don't organize" is one cosmetic pair plus one dialect pair, and slipped
    through while this compared the joined strings."""
    o, n = old.split(), new.split()
    if not o or len(o) != len(n):          # insertion/deletion: judge as a whole
        return _pair_ignorable(old, new)
    return all(_pair_ignorable(a, b) for a, b in zip(o, n))


# ---------------------------------------------------------------------------
# diff_issues — locate each edit as a character span in the ORIGINAL text.
# A cursor walk rather than index arithmetic: the backends return detokenized
# text whose spacing may not match the source word for word, so we find each
# source word forward from where the last one ended. Pure; unit-tested.
# ---------------------------------------------------------------------------
def diff_issues(source: str, corrected: str, base: int = 0) -> list[dict]:
    import difflib
    s_words, c_words = source.split(), corrected.split()
    issues, cursor = [], 0
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, s_words, c_words,
                                                      autojunk=False).get_opcodes():
        # Adjacent edits arrive as ONE opcode. Trim noise pairs off both ends so
        # "theres „only“" -> "there's \"only\"" reports just the apostrophe and
        # accepting it does not also swap the user's quote style.
        if op == "replace" and i2 - i1 == j2 - j1:
            while i1 < i2 and _pair_ignorable(s_words[i1], c_words[j1]):
                i1, j1 = i1 + 1, j1 + 1
            while i2 > i1 and _pair_ignorable(s_words[i2 - 1], c_words[j2 - 1]):
                i2, j2 = i2 - 1, j2 - 1
        # advance the cursor across every source word this opcode covers
        start, end = None, cursor
        for w in s_words[i1:i2]:
            found = source.find(w, end)
            if found < 0:
                continue
            if start is None:
                start = found
            end = found + len(w)
        if op == "equal":
            cursor = end
            continue
        old, new = " ".join(s_words[i1:i2]), " ".join(c_words[j1:j2])
        if start is None:                 # pure insertion: zero-width at cursor
            start = end = cursor
        cursor = end
        if should_ignore(old, new):
            continue
        # ponytail: a stop appended to the LAST word is the model finishing a
        # note fragment, not a fix. Mid-line ("home Then") is still reported.
        if end == len(source) and new[:-1] == old and new[-1:] in (".", "!", "?"):
            continue
        start, end, old, new = _widen(source, start, end, old, new)
        issues.append({"start": start, "end": end, "original": old, "suggestion": new})
    return [dict(i, start=base + i["start"], end=base + i["end"]) for i in coalesce(issues, source)]


def coalesce(issues: list[dict], source: str) -> list[dict]:
    """Merge spans whose gap is only whitespace: the word diff aligns on a
    shared word and returns fragments of one rewrite that only read together.
    The gap text is unchanged by definition, so it joins the suggestions."""
    out: list[dict] = []
    for iss in issues:
        gap = source[out[-1]["end"]:iss["start"]] if out else None
        if out and gap is not None and gap.strip() == "":
            prev = out[-1]
            prev["end"] = iss["end"]
            prev["original"] = source[prev["start"]:iss["end"]]
            prev["suggestion"] = prev["suggestion"] + gap + iss["suggestion"]
        else:
            out.append(dict(iss))
    return out


_WORD = re.compile(r"\S+")


def _widen(source: str, start: int, end: int, old: str, new: str):
    """Grow insertions and deletions to swallow a neighbouring word, so every
    issue is a straight span replacement. Without this the client would have to
    decide where the space goes — inserting "in" at a zero-width point yields
    "stillin", and deleting "more" leaves a double space behind."""
    if old and new:
        return start, end, old, new
    nxt = _WORD.search(source, end)
    if nxt:
        return (start if old else nxt.start(), nxt.end(),
                (old + " " + nxt.group() if old else nxt.group()),
                (new + " " + nxt.group() if new else nxt.group()))
    prev = None
    for m in _WORD.finditer(source, 0, start):
        prev = m
    if prev:
        return (prev.start(), end if old else prev.end(),
                prev.group() + " " + old if old else prev.group(),
                prev.group() + " " + new if new else prev.group())
    return start, end, old, new


# ---------------------------------------------------------------------------
# Backends
# ---------------------------------------------------------------------------
def _load_encoder():
    import torch
    from transformers import AutoModel, AutoTokenizer
    torch.set_num_threads(int(os.environ.get("GHOSTTYPE_SPELL_THREADS", "4")))
    model = AutoModel.from_pretrained(ENCODER_MODEL, trust_remote_code=True).float().eval()
    tok = AutoTokenizer.from_pretrained(ENCODER_MODEL)

    def correct(cores: list[str], model: str | None = None) -> list[str]:
        srcs = [tokenize(c) for c in cores]   # `model` is an Ollama-only knob
        keep, out = [], [None] * len(cores)
        for i, src in enumerate(srcs):
            if len(tok.encode(src, add_special_tokens=False)) > MAX_LEN - 1:
                out[i] = cores[i]         # never hand it something it would truncate
            else:
                keep.append(i)
        if keep:
            with _lock:                   # torch inference, one at a time
                got = model.correct([srcs[i] for i in keep], max_iter=MAX_ITER,
                                    batch_size=64, rerank=False,
                                    min_error_prob=MIN_ERROR_PROB)
            for i, g in zip(keep, got):
                out[i] = detok(g)
        return out
    return correct


def _load_ollama():
    def correct(cores: list[str], model: str | None = None) -> list[str]:
        out = []
        for core in cores:
            try:
                r = requests.post(f"{OLLAMA_URL}/api/generate", timeout=60, json={
                    "model": model or OLLAMA_MODEL, "prompt": PROMPT.format(s=core),
                    "stream": False, "keep_alive": "10m",
                    "think": False,       # see header: 35x faster AND more accurate
                    "options": {"temperature": 0, "num_ctx": 1024, "num_predict": 300},
                })
                t = r.json().get("response", "").strip().split("\n")[0].strip()
                t = re.sub(r"^(Corrected|Correction|Output)\s*:\s*", "", t, flags=re.I)
                t = t.strip().strip('"“”`*').strip()
            except Exception:
                t = ""
            # A model that refused, explained itself, or truncated is worse than
            # silence: fall back to "no issues" rather than invent suggestions.
            out.append(t if t and 0.4 * len(core) < len(t) < 2.5 * len(core) else core)
        return out
    return correct


# The master on/off toggle lives in the Hammerspoon config, same file the FIM
# server reads — one switch turns off every GhostType surface.
CONFIG_PATH = os.path.expanduser("~/.config/ghosttype/config.json")


def _enabled() -> bool:
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f).get("enabled", True)
    except Exception:
        return True  # missing/corrupt config never turns checking off


@asynccontextmanager
async def lifespan(app: FastAPI):
    _state["correct"] = _load_encoder() if BACKEND == "encoder" else _load_ollama()
    _state["ready"] = True
    yield


app = FastAPI(lifespan=lifespan)


class CheckReq(BaseModel):
    text: str = ""
    # Second opinion: the client's [b] / ⌘⌥⇧S re-check names a bigger model
    # (gemma4:31b catches real-word errors e4b misses — "Course" -> "Courts" —
    # at ~2.5 s/sentence vs 0.2 s, measured 2026-10-08). Per call, never sticky.
    model: str | None = None


# Accept/skip reports from the Obsidian plugin. Same line shape as the
# Hammerspoon client's SPELL lines in predictions.log, so one grep covers both;
# this file is append-only (no per-launch rotation to lose it to).
SPELL_LOG = os.path.expanduser("~/Library/Logs/ghosttype/spellcheck.log")


def event_line(ev: dict) -> str:
    q = lambda v: json.dumps(v, ensure_ascii=False)
    return f'SPELL app={q(ev.get("app", "?"))} {ev["kind"].upper()} {q(ev.get("original", ""))} → {q(ev.get("suggestion", ""))}'


class EventReq(BaseModel):
    kind: str
    app: str = "Obsidian"
    original: str = ""
    suggestion: str = ""


@app.post("/event")
def event(req: EventReq):
    os.makedirs(os.path.dirname(SPELL_LOG), exist_ok=True)
    with open(SPELL_LOG, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + event_line(req.model_dump()) + "\n")
    return {"ok": True}


@app.get("/ready")
def ready():
    return Response(status_code=200 if _state["ready"] else 503)


@app.get("/backend")
def backend():
    return {"backend": BACKEND,
            "model": OLLAMA_MODEL if BACKEND == "ollama" else ENCODER_MODEL,
            "dialect": DIALECT}


@app.post("/check")
def check(req: CheckReq):
    """Report issues; never rewrite. `corrected` is offered for an apply-all
    convenience, but the client is expected to drive `issues`."""
    if not _state["ready"] or not _enabled() or not req.text.strip():
        return {"issues": [], "corrected": req.text, "skipped": []}

    todo, skipped = plan_sentences(req.text)
    issues: list[dict] = []
    corrected = req.text
    if todo:
        outs = _state["correct"]([core for _, core in todo], req.model)
        for (base, core), out in zip(todo, outs):
            issues.extend(diff_issues(core, out, base))
        # apply-all text, built by replacing spans right-to-left
        for iss in sorted(issues, key=lambda i: -i["start"]):
            corrected = corrected[:iss["start"]] + iss["suggestion"] + corrected[iss["end"]:]

    return {"issues": issues, "corrected": corrected, "skipped": skipped}
