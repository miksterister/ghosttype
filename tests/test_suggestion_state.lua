package.path = "./?.lua;./tests/?.lua;" .. package.path
require("hs_stub")
local T = require("testlib")
local state = require("suggestion_state")

T.eq(state.cleanSuggestion(nil), "", "nil suggestion")
T.eq(state.cleanSuggestion("hello world   "), "hello world", "trim trailing")
T.eq(state.cleanSuggestion("first line\nsecond line"), "first line", "first line only")
T.eq(state.cleanSuggestion("first\r\nsecond"), "first", "strip carriage returns")

local handled, remaining = state.reuseSuggestion({ prefix = "hello", text = " world" }, "hello w")
T.eq(handled, true, "reuse handles typed prefix")
T.eq(remaining, "orld", "reuse remaining")

handled, remaining = state.reuseSuggestion({ prefix = "hello", text = " world" }, "hello world")
T.eq(handled, true, "reuse handles fully typed")
T.eq(remaining, nil, "fully typed has no remaining")

handled, remaining = state.reuseSuggestion({ prefix = "hello", text = " world" }, "hellx")
T.eq(handled, false, "diverged base refetches")
T.eq(remaining, nil, "diverged no remaining")

handled, remaining = state.reuseSuggestion({ prefix = "hello", text = " world" }, "hello z")
T.eq(handled, false, "typed off-script refetches")
T.eq(remaining, nil, "off-script no remaining")

-- Past maxPrefixChars the prefixes are sliding windows; reuse must still fire.
local CAP = 800
local function window(s) return #s <= CAP and s or s:sub(#s - CAP + 1) end
local long = string.rep("filler text ", 90) .. "APIs are used"
handled, remaining = state.reuseSuggestion(
  { prefix = window(long), text = " to communicate" }, window(long .. " to"))
T.eq(handled, true, "reuse fires past maxPrefixChars (sliding window)")
T.eq(remaining, " communicate", "windowed reuse remaining")
handled = state.reuseSuggestion(
  { prefix = window(long), text = " to communicate" }, window(long .. " z"))
T.eq(handled, false, "windowed off-script still refetches")

-- caret-boundary sanitization: trim trailing whitespace off the prompt
local p, didTrim = state.trimPromptEnd("The quick brown fox ")
T.eq(p, "The quick brown fox", "trimPromptEnd strips trailing space")
T.eq(didTrim, true, "trimPromptEnd reports it trimmed")
p, didTrim = state.trimPromptEnd("mid-word")
T.eq(p, "mid-word", "trimPromptEnd leaves clean boundary")
T.eq(didTrim, false, "trimPromptEnd reports no trim")
p, didTrim = state.trimPromptEnd("two spaces  ")
T.eq(p, "two spaces", "trimPromptEnd strips multiple trailing spaces")
T.eq(didTrim, true, "trimPromptEnd reports trim for multiple")

-- reconcile: drop leading space only when we trimmed (space already typed)
T.eq(state.reconcileLeadingSpace(" jumps over", true), "jumps over", "reconcile drops leading space after trim")
T.eq(state.reconcileLeadingSpace("jumps over", true), "jumps over", "reconcile no-op when no leading space")
T.eq(state.reconcileLeadingSpace(" jumps over", false), " jumps over", "reconcile keeps leading space when not trimmed")

-- mid-line detection: suppress when non-space text follows the caret on the line

-- nextChunk: next word with leading whitespace, for §  word-accept
local c, r = state.nextChunk("world peace")
T.eq(c, "world", "chunk: first word"); T.eq(r, " peace", "chunk: rest keeps space")
c, r = state.nextChunk(" peace")
T.eq(c, " peace", "chunk: leading space included"); T.eq(r, "", "chunk: rest empty")
c, r = state.nextChunk(", and then")
T.eq(c, ",", "chunk: punctuation alone"); T.eq(r, " and then", "chunk: rest after punct")
T.eq(state.nextChunk("   "), nil, "chunk: whitespace only")
T.eq(state.nextChunk(nil), nil, "chunk: nil")

-- ── documentTitle / titleFrame ───────────────────────────────────────────────
-- Ported from the Obsidian plugin, which frames the FIM prefix with "# <note
-- basename>". Hammerspoon has no metadataCache, only a window title — and a
-- window title is frequently NOT a document name. Every fixture below is a real
-- title read off a live app on 2026-09-18.

-- Claude desktop titles its window with the app name. Prepending "# Claude"
-- would put a meaningless heading on every request in the most-used app, and
-- base models parrot what you prepend (the personalization-fragment lesson).
T.eq(state.documentTitle("Claude", "Claude"), nil, "app-name title refused")
T.eq(state.documentTitle("Claude", "claude"), nil, "app-name match is case-insensitive")

-- Typora: a genuine filename, the closest thing to the plugin's file.basename.
T.eq(state.documentTitle("Typora", "Local LLMs - Interactive Study Outline.md"),
  "Local LLMs - Interactive Study Outline", "extension stripped, inner dashes kept")

-- Arc carries an unread badge on the tab title.
T.eq(state.documentTitle("Arc", "(1) A routine repair exposed problems"),
  "A routine repair exposed problems", "unread badge stripped")
T.eq(state.documentTitle("Arc", "(12) Something"), "Something", "multi-digit badge stripped")

-- Office appends app-name chrome with an em dash; plain hyphens too.
T.eq(state.documentTitle("Microsoft Word", "Q3 Report — Microsoft Word"),
  "Q3 Report", "em-dash app chrome stripped")
T.eq(state.documentTitle("Typora", "Draft - Typora"), "Draft", "hyphen app chrome stripped")

-- Nothing worth framing with.
T.eq(state.documentTitle("Notes", nil), nil, "nil title")
T.eq(state.documentTitle("Notes", ""), nil, "empty title")
T.eq(state.documentTitle("Notes", "   "), nil, "whitespace title")
T.eq(state.documentTitle("Notes", "Untitled"), nil, "Untitled is not a document name")
T.eq(state.documentTitle("Notes", "Untitled 2"), nil, "Untitled N is not a document name")
T.eq(state.documentTitle("Notes", "ab"), nil, "too short to mean anything")
T.eq(state.documentTitle("Word", "Doc — Word"), "Doc", "a short name is still a name")
-- but stripping chrome CAN leave nothing but the app name, which is refused
T.eq(state.documentTitle("Word", "Word — Word"), nil, "chrome strip exposing the app name is refused")

-- A title that merely CONTAINS the app name is still a real title.
T.eq(state.documentTitle("Notes", "Notes on the caret bug"), "Notes on the caret bug",
  "app name as a word is not app-name chrome")

-- titleFrame: the plugin's exact markdown framing, or nothing at all.
T.eq(state.titleFrame("Typora", "Draft ideas.md"), "# Draft ideas\n\n", "frame format")
T.eq(state.titleFrame("Claude", "Claude"), "", "no frame when there is no real title")
T.eq(state.titleFrame("Notes", nil), "", "no frame without a title")

-- caughtUp: AX lagging the keystroke must read as "not yet".
T.eq(state.caughtUp("ok y", "e"), false, "stale AX read before the typed char lands")
T.eq(state.caughtUp("ok ye", "e"), true, "typed char present")
T.eq(state.caughtUp("ok ye", nil), true, "no expectation (delete/return)")
T.eq(state.caughtUp("café", "é"), true, "multibyte typed char")

T.finish("suggestion_state")