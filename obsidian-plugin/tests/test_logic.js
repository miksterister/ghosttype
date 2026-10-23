// Runnable check for the plugin's pure logic. Run: node tests/test_logic.js
const assert = require("assert");
const { pure } = require("../main.js");
const { cleanSuggestion, advanceSuggestion, trimToWords, nextChunk, headingPath, inExcludedSection, paragraphAt, cpToJsIndex, unitAt } = pure;

// cleanSuggestion: first line only, ≤4 words, trailing whitespace trimmed
assert.strictEqual(cleanSuggestion("hello world"), "hello world");
assert.strictEqual(cleanSuggestion("line one\nline two"), "line one");
assert.strictEqual(cleanSuggestion("padded   \n"), "padded");
assert.strictEqual(cleanSuggestion(""), "");
assert.strictEqual(cleanSuggestion(null), "");
assert.strictEqual(cleanSuggestion("one two three four five six"), "one two three four");

// trimToWords: preserves internal spacing, no-op under the cap
assert.strictEqual(trimToWords("a  b   c d e", 4), "a  b   c d");
assert.strictEqual(trimToWords("just three words", 4), "just three words");
assert.strictEqual(trimToWords("  leading space kept here ok", 2), "  leading space");

// nextChunk: next word with its leading whitespace, plus the remainder
assert.deepStrictEqual(nextChunk("world peace"), { chunk: "world", rest: " peace" });
assert.deepStrictEqual(nextChunk(" peace"), { chunk: " peace", rest: "" });
assert.deepStrictEqual(nextChunk(", and then"), { chunk: ",", rest: " and then" });
assert.strictEqual(nextChunk("   "), null);
assert.strictEqual(nextChunk(""), null);

// advanceSuggestion: typed-through reuse
const sug = { pos: 10, text: "world peace" };
// typing the next characters of the ghost advances it
assert.deepStrictEqual(advanceSuggestion(sug, 10, 10, "wo"), { pos: 12, text: "rld peace" });
// typing the whole ghost consumes it
assert.strictEqual(advanceSuggestion(sug, 10, 10, "world peace"), null);
// typing off-script drops it
assert.strictEqual(advanceSuggestion(sug, 10, 10, "x"), null);
// an edit somewhere else drops it
assert.strictEqual(advanceSuggestion(sug, 3, 3, "wo"), null);
// a deletion (from != to) drops it
assert.strictEqual(advanceSuggestion(sug, 9, 10, ""), null);
// no ghost, no advance
assert.strictEqual(advanceSuggestion(null, 10, 10, "w"), null);

// headingPath: enclosing chain, siblings replaced, window-visible ones excluded
const H = (heading, level, offset) => ({ heading, level, position: { start: { offset } } });
const hs = [H("Intro", 1, 0), H("Budget", 2, 100), H("Q3", 3, 200), H("Q4", 3, 400), H("People", 2, 600)];
// caret at 500 inside Q4: path is Intro > Budget > Q4 (Q3 replaced by sibling Q4)
assert.deepStrictEqual(
  headingPath(hs, 500, 450).map((h) => h.heading),
  ["Intro", "Budget", "Q4"]
);
// window reaches back to 150: Intro and Budget are outside, Q4 visible in-window
assert.deepStrictEqual(
  headingPath(hs, 500, 150).map((h) => h.heading),
  ["Intro", "Budget"]
);
// caret before any heading
assert.deepStrictEqual(headingPath(hs, 0, 0), []);
// no headings at all
assert.deepStrictEqual(headingPath([], 500, 0), []);
assert.deepStrictEqual(headingPath(null, 500, 0), []);

// inExcludedSection: no completions inside code fences / YAML frontmatter.
// Both endpoints inclusive — a caret on the fence line must not fire.
const S = (type, start, end) => ({ type, position: { start: { offset: start }, end: { offset: end } } });
const secs = [S("yaml", 0, 20), S("paragraph", 22, 80), S("code", 100, 150)];
assert.strictEqual(inExcludedSection(secs, 10), true);   // inside frontmatter
assert.strictEqual(inExcludedSection(secs, 120), true);  // inside code fence
assert.strictEqual(inExcludedSection(secs, 50), false);  // prose paragraph
assert.strictEqual(inExcludedSection(secs, 0), true);    // exactly at start.offset
assert.strictEqual(inExcludedSection(secs, 150), true);  // exactly at end.offset
assert.strictEqual(inExcludedSection(secs, 151), false); // immediately after end
assert.strictEqual(inExcludedSection(secs, 21), false);  // gap between sections
assert.strictEqual(inExcludedSection([], 10), false);    // no sections
assert.strictEqual(inExcludedSection(undefined, 10), false); // missing cache
assert.strictEqual(inExcludedSection([{ type: "code" }], 10), false); // malformed position

console.log("plugin logic: all passed");

// paragraphAt: the unit we send to the checker — must match spellcheck.lua
{
  const doc = "First para.\nSecond para here.\nThird.";
  assert.deepStrictEqual(paragraphAt(doc, 3), { from: 0, to: 11 });
  assert.strictEqual(doc.slice(0, 11), "First para.");
  const mid = paragraphAt(doc, 15);
  assert.strictEqual(doc.slice(mid.from, mid.to), "Second para here.");
  const last = paragraphAt(doc, 32);
  assert.strictEqual(doc.slice(last.from, last.to), "Third.");
  assert.deepStrictEqual(paragraphAt("only one line", 5), { from: 0, to: 13 });
  assert.deepStrictEqual(paragraphAt("", 0), { from: 0, to: 0 });
  // caret at the very start and sitting on a newline
  assert.deepStrictEqual(paragraphAt(doc, 0), { from: 0, to: 11 });
  assert.strictEqual(doc.slice(paragraphAt(doc, 11).from, paragraphAt(doc, 11).to), "First para.");
}

// cpToJsIndex: codepoint offset -> JS (UTF-16) index. Identical for plain text,
// divergent the moment an astral character appears — which is the whole point.
assert.strictEqual(cpToJsIndex("hello", 0), 0);
assert.strictEqual(cpToJsIndex("hello", 3), 3);
assert.strictEqual(cpToJsIndex("über", 2), 2);
assert.strictEqual(cpToJsIndex("a\u{1F600}b", 2), 3, "emoji is 2 UTF-16 units");
assert.strictEqual(cpToJsIndex("a\u{1F600}b", 3), 4);
assert.strictEqual(cpToJsIndex("hello", 99), 5, "past the end clamps");
{
  // the round trip that matters: slice exactly the span the server named
  const t = "Its a well know fact";
  assert.strictEqual(t.slice(cpToJsIndex(t, 6), cpToJsIndex(t, 15)), "well know");
  const e = "hi \u{1F600} its a well know fact";
  assert.strictEqual(e.slice(cpToJsIndex(e, 11), cpToJsIndex(e, 20)), "well know", "offset survives an emoji");
}

console.log("paragraphAt + cpToJsIndex: passed");

// unitAt: a non-empty selection is the unit to check (mirrors spellcheck.lua's
// unitBounds); a collapsed caret falls back to the paragraph.
{
  const doc = "first line\nsecond line\nthird";
  assert.deepStrictEqual(unitAt(doc, 3, 3), { from: 0, to: 10 });      // caret -> paragraph
  assert.deepStrictEqual(unitAt(doc, 6, 18), { from: 6, to: 18 });     // selection, multi-line
  assert.deepStrictEqual(unitAt(doc, 18, 6), { from: 6, to: 18 });     // backwards selection
  console.log("unitAt: passed");
}
