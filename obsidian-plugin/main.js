/* GhostType Inline — thin CodeMirror-6 renderer over the local GhostType FIM
   server (projects/ghosttype/server, port 8790). Same brain as the
   Hammerspoon overlay, but rendered natively inside the editor, so position,
   font, and wrapping are pixel-true.

   No build step: plain CommonJS. Obsidian provides "obsidian" and
   "@codemirror/*" to plugins at runtime; the try/catch below lets
   tests/test_logic.js require this file under plain node. */

const SERVER = "http://127.0.0.1:8790"; // ponytail: constants, not a settings tab — add one when a second person uses this
const SPELL_SERVER = "http://127.0.0.1:8791"; // the check server — suggests, never rewrites
const SPELL_DEEP_MODEL = "gemma4:31b"; // second opinion: ~2.5 s/sentence, catches real-word errors
const IDLE_MS = 260;
const MAX_PREFIX = 2000;
const MAX_SUFFIX = 200;
const MAX_TOKENS = 10; // ~4 words is all we keep — don't pay latency for more
const MIN_PREFIX = 3;
const MAX_WORDS = 4; // ghost text is a nudge, not a paragraph

let obsidian, cmView, cmState;
try {
  obsidian = require("obsidian");
  cmView = require("@codemirror/view");
  cmState = require("@codemirror/state");
} catch (e) {
  /* running under node for the logic self-test */
}

// ── Pure logic (node-testable) ──────────────────────────────────────────────

// Cap at the first maxWords words, preserving the original spacing between them.
function trimToWords(text, maxWords) {
  const re = /\S+/g;
  let m,
    count = 0;
  while ((m = re.exec(text))) {
    count++;
    if (count === maxWords) return text.slice(0, m.index + m[0].length);
  }
  return text;
}

// Keep only the first line, cap at MAX_WORDS words, trim trailing whitespace —
// ghost text is a short inline continuation, mirroring suggestion_state.lua.
function cleanSuggestion(text) {
  if (!text) return "";
  const nl = text.indexOf("\n");
  if (nl !== -1) text = text.slice(0, nl);
  return trimToWords(text, MAX_WORDS).replace(/\s+$/, "");
}

// The next word of a suggestion (with its leading whitespace) and what's left,
// for word-by-word acceptance. Returns null when there is no word to take.
function nextChunk(text) {
  const m = text && text.match(/^\s*\S+/);
  if (!m) return null;
  return { chunk: m[0], rest: text.slice(m[0].length) };
}

// The chain of headings enclosing `pos` (Obsidian metadataCache shape:
// {heading, level, position:{start:{offset}}}, sorted by offset), keeping only
// those that start before `windowStart` — headings inside the visible prefix
// window are already in the prompt verbatim.
function headingPath(headings, pos, windowStart) {
  const stack = [];
  for (const h of headings || []) {
    const off = h.position && h.position.start && h.position.start.offset;
    if (typeof off !== "number") continue;
    if (off > pos) break;
    while (stack.length && stack[stack.length - 1].level >= h.level) stack.pop();
    stack.push(h);
  }
  return stack.filter((h) => h.position.start.offset < windowStart);
}

// True when pos falls inside a section whose FIM output would be junk —
// fenced code blocks and YAML frontmatter. Both endpoints inclusive: a caret
// sitting on the fence line itself must not trigger a request. sections from
// metadataCache: {type, position:{start:{offset}, end:{offset}}}.
function inExcludedSection(sections, pos) {
  for (const s of sections || []) {
    if (s.type !== "code" && s.type !== "yaml") continue;
    const p = s.position;
    if (!p || !p.start || !p.end) continue;
    if (p.start.offset <= pos && pos <= p.end.offset) return true;
  }
  return false;
}

// Typed-through reuse: a single insertion exactly at the ghost anchor that
// matches the head of the suggestion advances it instead of dropping it.
// sug = {pos, text} in pre-change coords; returns the advanced ghost or null.
function advanceSuggestion(sug, from, to, inserted) {
  if (!sug || from !== sug.pos || to !== sug.pos) return null; // edit elsewhere, or a deletion
  if (!inserted || !sug.text.startsWith(inserted)) return null; // typed off-script
  const rest = sug.text.slice(inserted.length);
  return rest ? { pos: sug.pos + inserted.length, text: rest } : null; // null = fully typed
}

// Paragraph bounds around `pos`. Mirrors spellcheck.lua's paragraphBounds so
// both clients send the checker the same unit of text.
function paragraphAt(text, pos) {
  const from = text.lastIndexOf("\n", Math.max(0, pos - 1)) + 1;
  let to = text.indexOf("\n", pos);
  if (to === -1) to = text.length;
  return { from, to };
}

// The unit to check: a non-empty selection as-is (multi-line is fine), else the
// paragraph around the caret. Mirrors spellcheck.lua's unitBounds.
function unitAt(text, anchor, head) {
  const from = Math.min(anchor, head), to = Math.max(anchor, head);
  return from === to ? paragraphAt(text, head) : { from, to };
}

// The server reports offsets in CODEPOINTS (Python string indices); JS strings
// are UTF-16. They agree until someone types an emoji, at which point every
// later span would land one unit short and we would underline — and replace —
// the wrong characters.
function cpToJsIndex(text, cp) {
  if (cp <= 0) return 0;
  let n = 0,
    i = 0;
  while (i < text.length && n < cp) {
    i += text.codePointAt(i) > 0xffff ? 2 : 1;
    n++;
  }
  return i;
}

// ── CM6 extension ───────────────────────────────────────────────────────────

// Fire-and-forget outcome report so the Hammerspoon menubar tally includes
// Obsidian (it reads the server's /stats when opened).
function postEvent(kind) {
  try {
    obsidian
      .requestUrl({
        url: SERVER + "/event",
        method: "POST",
        contentType: "application/json",
        body: JSON.stringify({ kind }),
      })
      .catch(() => {});
  } catch (e) {
    /* never let telemetry break typing */
  }
}

// Accept/skip report for a checker row → ~/Library/Logs/ghosttype/spellcheck.log
// (the Hammerspoon panel writes the same SPELL lines to predictions.log).
function postSpellEvent(kind, issue) {
  try {
    obsidian
      .requestUrl({
        url: SPELL_SERVER + "/event",
        method: "POST",
        contentType: "application/json",
        body: JSON.stringify({ kind, app: "Obsidian", original: issue.original, suggestion: issue.suggestion }),
      })
      .catch(() => {});
  } catch (e) {
    /* never let telemetry break editing */
  }
}

function buildExtension(plugin) {
  const { Decoration, EditorView, WidgetType, ViewPlugin, keymap } = cmView;
  const { StateField, StateEffect, Prec } = cmState;

  const setGhost = StateEffect.define();
  const setIssues = StateEffect.define();   // [{from, to, original, suggestion}]
  const clearIssue = StateEffect.define();  // {from, to} in PRE-change coords

  class GhostWidget extends WidgetType {
    constructor(text) {
      super();
      this.text = text;
    }
    toDOM() {
      const span = document.createElement("span");
      span.className = "ghosttype-ghost";
      span.textContent = this.text;
      return span;
    }
    eq(other) {
      return other.text === this.text;
    }
  }

  const ghostField = StateField.define({
    create: () => null, // {pos, text} | null
    update(value, tr) {
      // A transaction carrying a setGhost effect already accounts for its own
      // doc change (partial accept edits AND re-anchors in one dispatch) —
      // skip the typed-through advance for those.
      let explicit = false;
      for (const e of tr.effects)
        if (e.is(setGhost)) {
          value = e.value;
          explicit = true;
        }
      if (value && tr.docChanged && !explicit) {
        let single = null;
        let count = 0;
        tr.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
          count++;
          single = { from: fromA, to: toA, inserted: inserted.toString() };
        });
        value =
          count === 1
            ? advanceSuggestion(value, single.from, single.to, single.inserted)
            : null;
      }
      // Caret moved off the anchor (arrows, click) — the context changed.
      if (value) {
        const sel = tr.state.selection.main;
        if (!sel.empty || sel.head !== value.pos) value = null;
      }
      return value;
    },
    provide: (f) =>
      EditorView.decorations.from(f, (v) =>
        v
          ? Decoration.set([
              Decoration.widget({ widget: new GhostWidget(v.text), side: 1 }).range(v.pos),
            ])
          : Decoration.none
      ),
  });

  // Underlines for the checker's findings. Unlike the Hammerspoon panel — which
  // has to close after one accept because AX offsets go stale — CM6 remaps the
  // remaining decorations through every edit, so accepting one suggestion leaves
  // the others correctly positioned.
  const issueField = StateField.define({
    create: () => Decoration.none,
    update(deco, tr) {
      // Filter BEFORE mapping: a clearIssue effect carries the range in the
      // coordinates that existed when the click happened.
      for (const e of tr.effects)
        if (e.is(clearIssue))
          deco = deco.update({ filter: (f, t) => !(f === e.value.from && t === e.value.to) });
      deco = deco.map(tr.changes);
      for (const e of tr.effects)
        if (e.is(setIssues))
          deco = Decoration.set(
            e.value.map((i) =>
              Decoration.mark({
                class: "ghosttype-issue",
                attributes: { title: i.original + " → " + i.suggestion },
                issue: i,
              }).range(i.from, i.to)
            ),
            true
          );
      return deco;
    },
    provide: (f) => EditorView.decorations.from(f),
  });

  function issueAt(view, pos) {
    let hit = null;
    view.state.field(issueField).between(pos, pos, (from, to, value) => {
      hit = { from, to, issue: value.spec.issue };
      return false;
    });
    return hit;
  }

  const clicks = EditorView.domEventHandlers({
    mousedown(event, view) {
      const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
      if (pos == null) return false;
      const hit = issueAt(view, pos);
      if (!hit || !obsidian) return false;
      const menu = new obsidian.Menu();
      menu.addItem((item) =>
        item
          .setTitle('Replace with "' + hit.issue.suggestion + '"')
          .setIcon("check")
          .onClick(() => {
            view.dispatch({
              changes: { from: hit.from, to: hit.to, insert: hit.issue.suggestion },
              effects: clearIssue.of({ from: hit.from, to: hit.to }),
            });
            postSpellEvent("accept", hit.issue);
          })
      );
      menu.addItem((item) =>
        item
          .setTitle("Ignore")
          .setIcon("x")
          .onClick(() => {
            view.dispatch({ effects: clearIssue.of({ from: hit.from, to: hit.to }) });
            postSpellEvent("skip", hit.issue);
          })
      );
      menu.showAtMouseEvent(event);
      return true;
    },
  });

  const fetcher = ViewPlugin.fromClass(
    class {
      constructor(view) {
        this.view = view;
        this.timer = null;
        this.reqId = 0;
      }
      update(u) {
        if (!u.docChanged) return;
        if (u.state.field(ghostField)) return; // typed-through ghost still showing
        clearTimeout(this.timer);
        this.timer = setTimeout(() => this.fetch(), IDLE_MS);
      }
      async fetch() {
        const view = this.view;
        if (view.composing) return; // IME in progress
        const state = view.state;
        const sel = state.selection.main;
        if (!sel.empty || state.field(ghostField)) return;
        const pos = sel.head;
        const doc = state.doc;
        const windowStart = Math.max(0, pos - MAX_PREFIX);
        const prefix = doc.sliceString(windowStart, pos);
        if (prefix.trim().length < MIN_PREFIX) return;
        const suffix = doc.sliceString(pos, Math.min(doc.length, pos + MAX_SUFFIX));

        // Never complete inside code fences or YAML frontmatter. Missing
        // cache/sections = allow — context is a bonus, never a blocker.
        try {
          const f = plugin.app.workspace.getActiveFile();
          const c = f && plugin.app.metadataCache.getFileCache(f);
          if (c && inExcludedSection(c.sections, pos)) return;
        } catch (e) {}

        // Frame the window with what the model can't see: the note's title and
        // the headings enclosing the caret that scrolled out of the window.
        // Rendered as markdown so the FIM prompt stays one coherent document.
        let context = "";
        try {
          const file = plugin.app.workspace.getActiveFile();
          if (file) {
            context += "# " + file.basename + "\n";
            const cache = plugin.app.metadataCache.getFileCache(file);
            for (const h of headingPath((cache && cache.headings) || [], pos, windowStart))
              context += "#".repeat(h.level) + " " + h.heading + "\n";
            context += "\n";
          }
        } catch (e) {
          /* canvas/embed edge cases — context is a bonus, never a blocker */
        }

        const id = ++this.reqId;
        let text;
        try {
          // requestUrl (not fetch): Obsidian's app:// origin makes fetch a CORS victim.
          const res = await obsidian.requestUrl({
            url: SERVER + "/complete",
            method: "POST",
            contentType: "application/json",
            body: JSON.stringify({ prefix: context + prefix, suffix, max_tokens: MAX_TOKENS, max_words: MAX_WORDS }),
          });
          text = cleanSuggestion((res.json && res.json.text) || "");
        } catch (e) {
          return; // server down/slow — a missed suggestion stays silent
        }
        if (id !== this.reqId || !text) return;
        // Caret may have moved while the request was in flight.
        const now = view.state.selection.main;
        if (!now.empty || now.head !== pos) return;
        if (view.state.doc.sliceString(Math.max(0, pos - MAX_PREFIX), pos) !== prefix) return;
        view.dispatch({ effects: setGhost.of({ pos, text }) });
        postEvent("shown");
      }
      destroy() {
        clearTimeout(this.timer);
      }
    }
  );

  const keys = Prec.highest(
    keymap.of([
      {
        key: "§", // top-left key, no modifier — accept the whole suggestion
        run(view) {
          const v = view.state.field(ghostField);
          if (!v) return false; // no ghost: § types normally
          view.dispatch({
            changes: { from: v.pos, insert: v.text },
            selection: { anchor: v.pos + v.text.length },
            effects: setGhost.of(null),
          });
          postEvent("accepted");
          return true;
        },
      },
      {
        key: "Tab", // accept one word, keep the rest as ghost
        run(view) {
          const v = view.state.field(ghostField);
          if (!v) return false; // let Obsidian's own Tab (indent, lists) run
          const part = nextChunk(v.text);
          if (!part) return false;
          const at = v.pos + part.chunk.length;
          view.dispatch({
            changes: { from: v.pos, insert: part.chunk },
            selection: { anchor: at },
            effects: setGhost.of(part.rest ? { pos: at, text: part.rest } : null),
          });
          if (!part.rest) postEvent("accepted"); // Tab-chain consumed the whole ghost
          return true;
        },
      },
      {
        key: "Escape",
        run(view) {
          if (view.state.field(ghostField)) {
            view.dispatch({ effects: setGhost.of(null) });
            postEvent("dismissed");
            return true;
          }
          // No ghost, but underlines showing: Escape dismisses those instead.
          if (view.state.field(issueField).size) {
            view.dispatch({ effects: setIssues.of([]) });
            return true;
          }
          return false;
        },
      },
    ])
  );

  return { extension: [ghostField, issueField, fetcher, clicks, keys], setIssues };
}

// ── Plugin shell ────────────────────────────────────────────────────────────

// Ask the check server about the paragraph under the caret and underline what
// it flags. Nothing is rewritten here — every change goes through a click.
// `model` names the second-opinion model (per call, never sticky).
async function checkParagraph(view, setIssues, model) {
  const doc = view.state.doc.toString();
  const sel = view.state.selection.main;
  const { from, to } = unitAt(doc, sel.anchor, sel.head);
  const text = doc.slice(from, to);
  if (!text.trim()) {
    new obsidian.Notice("GhostType: nothing to check");
    return;
  }
  if (model) new obsidian.Notice("GhostType: checking with " + model + "…", 1500);
  let data;
  try {
    const res = await obsidian.requestUrl({
      url: SPELL_SERVER + "/check",
      method: "POST",
      contentType: "application/json",
      body: JSON.stringify(model ? { text, model } : { text }),
    });
    data = res.json;
  } catch (e) {
    new obsidian.Notice("GhostType: check server not reachable (" + SPELL_SERVER + ")");
    return;
  }
  const issues = (data.issues || []).map((i) => ({
    from: from + cpToJsIndex(text, i.start),
    to: from + cpToJsIndex(text, i.end),
    original: i.original,
    suggestion: i.suggestion,
  }));
  view.dispatch({ effects: setIssues.of(issues) });
  if (!issues.length) {
    new obsidian.Notice(
      (data.skipped || []).length ? "GhostType: skipped (not English)" : "GhostType: no issues"
    );
  }
}

class GhostTypeInlinePlugin extends (obsidian ? obsidian.Plugin : class {}) {
  onload() {
    const built = buildExtension(this);
    this.registerEditorExtension(built.extension);
    this.addCommand({
      id: "check-paragraph",
      name: "Check paragraph (spelling & grammar)",
      editorCallback: (editor) => {
        // editor.cm is the CM6 EditorView; the whole feature needs it, so bail
        // loudly rather than silently doing nothing on an older Obsidian.
        if (!editor.cm) {
          new obsidian.Notice("GhostType: needs a CodeMirror 6 editor");
          return;
        }
        checkParagraph(editor.cm, built.setIssues);
      },
    });
    this.addCommand({
      id: "check-paragraph-deep",
      name: "Check paragraph with bigger model (spelling & grammar)",
      editorCallback: (editor) => {
        if (!editor.cm) {
          new obsidian.Notice("GhostType: needs a CodeMirror 6 editor");
          return;
        }
        checkParagraph(editor.cm, built.setIssues, SPELL_DEEP_MODEL);
      },
    });
  }
}

module.exports = GhostTypeInlinePlugin;
module.exports.pure = { cleanSuggestion, advanceSuggestion, trimToWords, nextChunk, headingPath, inExcludedSection, paragraphAt, cpToJsIndex, unitAt };
