package.path = "./?.lua;./tests/?.lua;" .. package.path
require("hs_stub")
local T = require("testlib")
local log = require("log")

-- tail: short context is returned unchanged
T.eq(log.tail("hello", 40), "hello", "tail short unchanged")
-- tail: long context is truncated with a leading ellipsis, keeping the last n
T.eq(log.tail("abcdefghij", 4), "…ghij", "tail truncates to last n")
-- tail: newlines are flattened to spaces (single-line log)
T.eq(log.tail("a\nb", 40), "a b", "tail flattens newlines")
-- tail: nil context is safe
T.eq(log.tail(nil, 40), "", "tail nil safe")

-- format: a shown suggestion
T.eq(
  log.format({ app = "Notes", ctx = "the quick ", outcome = "shown", text = "brown fox" }),
  'PREDICT app="Notes" ctx="the quick " → SHOWN "brown fox"',
  "format shown"
)
T.eq(
  log.format({ app = "Claude", ctx = "", outcome = "accepted", text = " world" }),
  'PREDICT app="Claude" ctx="" → ACCEPTED " world"',
  "format accepted"
)
-- format: a suppression carries its reason
T.eq(
  log.format({ app = "Claude", ctx = "def main(", outcome = "suppress", reason = "mid-line" }),
  'PREDICT app="Claude" ctx="def main(" → SUPPRESS(mid-line)',
  "format suppress"
)
-- format: a reused (locally trim-served) suggestion
T.eq(
  log.format({ app = "Notes", ctx = "hel", outcome = "reused", text = "lo" }),
  'PREDICT app="Notes" ctx="hel" → REUSED "lo"',
  "format reused"
)
-- format: context is tail-trimmed using ctxChars
T.eq(
  log.format({ app = "Mail", ctx = "abcdefghij", ctxChars = 4, outcome = "suppress", reason = "min-prefix" }),
  'PREDICT app="Mail" ctx="…ghij" → SUPPRESS(min-prefix)',
  "format trims ctx"
)

-- write: appends a timestamped line ending in the formatted body
local tmp = "/tmp/ghosttype-test-predictions.log"
os.remove(tmp)
log.write({ app = "Notes", ctx = "x", outcome = "shown", text = "y" }, tmp)
local f = io.open(tmp, "r"); local contents = f:read("*a"); f:close()
T.ok(contents:find('PREDICT app="Notes" ctx="x" → SHOWN "y"', 1, true), "write appends formatted body")
T.ok(contents:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d "), "write prepends timestamp")

-- reset: starts a fresh file but ROTATES the old one to .prev rather than
-- destroying it. The accept rate lives only in this file, and it used to be
-- wiped by the very reload you did to test a change.
log.reset(tmp)
f = io.open(tmp, "r"); contents = f:read("*a"); f:close()
T.eq(contents, "", "reset starts an empty current log")
local pf = io.open(tmp .. ".prev", "r")
local prev = pf and pf:read("*a") or ""
if pf then pf:close() end
T.ok(prev:find('SHOWN "y"', 1, true), "reset rotates the old log to .prev")

-- a second reset keeps only one generation back, and must not error when there
-- is no current log to rotate
log.write({ app = "Notes", ctx = "second", outcome = "shown", text = "z" }, tmp)
log.reset(tmp)
pf = io.open(tmp .. ".prev", "r"); prev = pf and pf:read("*a") or ""
if pf then pf:close() end
T.ok(prev:find('SHOWN "z"', 1, true), ".prev holds the most recent session")
T.eq(prev:find('SHOWN "y"', 1, true), nil, "only one generation is kept")
os.remove(tmp); os.remove(tmp .. ".prev")
log.reset(tmp) -- nothing to rotate: must not error
os.remove(tmp); os.remove(tmp .. ".prev")

-- format: a spellcheck run records what was sent and what came back, so a
-- "no issues" verdict is diagnosable from the log (added 2026-10-08 after a
-- Folio paragraph with three errors came back clean and nothing said why).
T.eq(
  log.format({ app = "Folio", ctx = "ly to be enforcable", outcome = "check", role = "AXTextArea", chars = 70, issues = 2, skipped = 0 }),
  'CHECK app="Folio" role="AXTextArea" chars=70 ctx="ly to be enforcable" → 2 issues, 0 skipped',
  "format check"
)
T.eq(
  log.format({ app = "Folio", ctx = "", outcome = "check", role = "?", chars = 0, status = 0 }),
  'CHECK app="Folio" role="?" chars=0 ctx="" → FAILED status=0',
  "format check failure"
)

-- accept / skip rows from the spellcheck panel: the only record of which
-- suggestions are worth showing (same lesson as ACCEPTED for completions)
T.eq(
  log.format({ app = "Folio", outcome = "spell-accept", original = "theres", suggestion = "there's" }),
  'SPELL app="Folio" ACCEPT "theres" → "there\'s"',
  "format spell accept"
)
T.eq(
  log.format({ app = "Folio", outcome = "spell-skip", original = "point", suggestion = "point," }),
  'SPELL app="Folio" SKIP "point" → "point,"',
  "format spell skip"
)

T.finish("log")
