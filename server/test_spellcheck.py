# Pure unit tests for the spellcheck server's decision logic — no model, no
# network. Run: ~/.venvs/ghosttype-spell/bin/python server/test_spellcheck.py
import spellcheck_server
from spellcheck_server import (detok, diff_issues, is_cosmetic, is_dialect_only,
                               event_line, looks_german, plan_sentences, should_ignore,
                               skip_sentence, split_sentences, strip_markdown_prefix,
                               to_american, tokenize)


def test():
    # --- split_sentences: chunks must rejoin to the exact input, or the offsets
    # we report would not point at the text the user is looking at.
    for text in ["One. Two! Three?", "no terminator", "", "A.  B.   ",
                 "Trailing space. ", "Dr. Smith went home.", "Multi\nline. Next."]:
        assert "".join(split_sentences(text)) == text, f"lossless: {text!r}"
    assert split_sentences("One. Two.") == ["One. ", "Two."], "splits on sentence end"
    assert split_sentences("") == [], "empty yields nothing"

    # --- tokenize/detok round trip on already-correct text
    for s in ["It's fine.", "Don't do that.", "He said (quietly) yes.",
              "The data show a trend."]:
        assert detok(tokenize(s)) == s, f"round trip: {s!r}"

    # --- looks_german: must catch German, must NOT catch English
    assert looks_german("Es ist wichtig, dass wir die Ergebnisse überprüfen."), "umlaut + words"
    assert looks_german("Wir haben das nicht gemacht und sind zu spat."), "stopwords, no umlaut"
    assert not looks_german("The man will die if we do not act."), "die/man are English too"
    assert not looks_german("However, forensic linguists deal with crimes of language."), "plain English"
    assert looks_german("We met in Zürich."), "umlaut alone is enough (safe direction)"

    # --- dialect guard
    assert to_american("analyse") == "analyze" and to_american("colour") == "color"
    assert to_american("four") == "four", "too short for the our rule"
    assert is_dialect_only("analyse", "analyze"), "the measured failure"
    assert is_dialect_only("analyses", "analyze"), "dialect wearing a plural"
    assert is_dialect_only("recognise", "recognize"), "measured on gemma4"
    assert not is_dialect_only("analyses", "analysis"), "real number fix survives"
    assert not is_dialect_only("occured", "occurred"), "real typo fix survives"
    assert not is_dialect_only("four", "for"), "short word is not a dialect pair"
    # found live 2026-10-08: a Folio paragraph came back "no issues" because the
    # ONLY fix the model made was swallowed here. Case-only and number-only
    # pairs are grammar, not dialect.
    assert not is_dialect_only("strike", "strikes"), "verb agreement is a real fix"
    assert not is_dialect_only("perform", "performs"), "verb agreement is a real fix"
    assert not is_dialect_only("cat", "cats"), "plural is a real fix"
    assert not is_dialect_only("english", "English"), "capitalisation is a real fix"
    assert not is_dialect_only("i", "I"), "capitalisation is a real fix"

    # --- cosmetic guard (gemma4 rewrites curly quotes; Obsidian produces them)
    assert is_cosmetic("don’t", "don't"), "curly apostrophe"
    assert is_cosmetic("“hi”", '"hi"'), "curly quotes"
    assert is_cosmetic("a—b", "a-b"), "em dash"
    assert is_cosmetic("„only“", '"only"'), "German low quotes (live 2026-10-08)"
    # Swiss German has no ß. gemma4 rewrote Strasse/grossen/weiss/gross in two
    # ordinary sentences (2026-10-08) — that is dialect, not an error.
    assert is_cosmetic("Strasse", "Straße") and is_cosmetic("grossen", "großen")
    assert not is_cosmetic("Strase", "Strasse"), "a real missing s is not cosmetic"
    assert diff_issues("Die Strasse war gesperrt", "Die Straße war gesperrt") == []
    assert is_cosmetic("‚x‘", "'x'"), "German single quotes"
    assert diff_issues("theres „only“ theft", "there's \"only\" theft") == \
        [{"start": 0, "end": 6, "original": "theres", "suggestion": "there's"}], "quote churn stays out of the span"
    assert not is_cosmetic("dont", "don't"), "a real missing apostrophe is NOT cosmetic"
    assert should_ignore("recognise", "recognize") and should_ignore("don’t", "don't")
    assert not should_ignore("occured", "occurred"), "real fixes are never ignored"
    # regressions found live against gemma4:e4b-mlx (2026-08-24)
    assert should_ignore("colour.", "color."), "trailing full stop must not defeat the dialect rule"
    assert should_ignore("don’t organise", "don't organize"), "merged span: cosmetic + dialect"
    assert should_ignore("(analyse)", "(analyze)"), "brackets stripped too"
    assert not should_ignore("well know", "well-known"), "real multi-word fix survives"
    assert not should_ignore("don’t organise", "don't organise it"), "uneven span is a real edit"

    # --- German gate: the encoder is English-only, gemma4 is not (5/5 planted
    # German errors fixed, measured 2026-10-08). Only the encoder skips.
    spellcheck_server.BACKEND = "encoder"
    assert skip_sentence("Wir haben das nicht gemacht und sind zu spat."), "encoder skips German"
    spellcheck_server.BACKEND = "ollama"
    assert not skip_sentence("Wir haben das nicht gemacht und sind zu spat."), "ollama checks German"
    assert not skip_sentence("plain English either way")

    # --- markdown line prefixes are syntax, not words to correct. The server
    # strips them so raw-markdown apps (Obsidian, Typora) stop getting
    # "> likely -> likely" rows; the returned offset keeps spans honest.
    for raw, core in [("> likely to be", "likely to be"),
                      ("> [!toggle]+ Companies try", "Companies try"),
                      ("- item one", "item one"),
                      ("1. first", "first"),
                      ("## Heading text", "Heading text"),
                      ("  > > nested", "nested"),
                      ("plain text", "plain text"),
                      ("a - b", "a - b")]:
        n, got = strip_markdown_prefix(raw)
        assert got == core and raw[n:] == core, f"{raw!r} -> {n}, {got!r}"

    # The prefix must come off BEFORE sentence splitting: the "!" in
    # "[!toggle]" is a sentence terminator, so splitting first left "> [!" as
    # its own sentence and the model "fixed" it to "[!]" (seen live 2026-10-08).
    spellcheck_server.BACKEND = "ollama"
    assert plan_sentences("> [!toggle]+ Companies try. Courts strike") == \
        ([(13, "Companies try."), (28, "Courts strike")], []), plan_sentences("> [!toggle]+ Companies try. Courts strike")
    spellcheck_server.BACKEND = "encoder"
    assert plan_sentences("- Wir sind zu spat und nicht da") == ([], ["german"])
    spellcheck_server.BACKEND = "ollama"
    # a multi-line selection: every line loses its own prefix, offsets stay honest
    multi = "> one here.\n- two there\nthree"
    plan, _ = plan_sentences(multi)
    assert [(multi[o:o + len(c)], c) for o, c in plan] == \
        [("one here.", "one here."), ("two there", "two there"), ("three", "three")], plan
    spellcheck_server.BACKEND = "ollama"

    # --- diff_issues: spans must point at the right characters
    src = "Those defining feature are simply the act."
    out = "The defining feature is simply the act."
    issues = diff_issues(src, out)
    assert len(issues) == 2, f"two issues: {issues}"
    assert src[issues[0]["start"]:issues[0]["end"]] == "Those", "span points at 'Those'"
    assert issues[0]["suggestion"] == "The", "suggestion carried"
    assert src[issues[1]["start"]:issues[1]["end"]] == "are", "span points at 'are'"

    # base offset shifts spans into the containing document
    issues = diff_issues(src, out, base=100)
    assert issues[0]["start"] == 100 and issues[0]["end"] == 105, f"offset applied: {issues[0]}"

    # a repeated word must not resolve to the FIRST occurrence
    src2 = "the cat sat on the mat"
    issues = diff_issues(src2, "the cat sat on the rug")
    assert src2[issues[0]["start"]:issues[0]["end"]] == "mat", f"last word, not first: {issues}"

    # insertion widens onto the next word so the client never has to place a
    # space: replacing "that" with "in that" is unambiguous, inserting at a
    # zero-width point is not.
    src3 = "pages still that book"
    issues = diff_issues(src3, "pages still in that book")
    assert len(issues) == 1, f"insertion: {issues}"
    assert issues[0]["original"] == "that" and issues[0]["suggestion"] == "in that", issues
    assert src3[issues[0]["start"]:issues[0]["end"]] == "that", "span covers the real word"

    # deletion widens the same way: "more stronger" -> "stronger"
    src4 = "is more stronger than"
    issues = diff_issues(src4, "is stronger than")
    assert issues[0]["original"] == "more stronger", f"deletion: {issues}"
    assert issues[0]["suggestion"] == "stronger", issues
    assert src4[issues[0]["start"]:issues[0]["end"]] == "more stronger", "span covers both"

    # a deletion at the very end falls back to the preceding word
    issues = diff_issues("this is very very", "this is very")
    assert issues[0]["original"] and issues[0]["suggestion"], f"no empty side: {issues}"

    # every issue must be a straight replacement — no empty side, ever
    for a, b in [("pages still that book", "pages still in that book"),
                 ("is more stronger than", "is stronger than"),
                 ("this is very very", "this is very")]:
        for iss in diff_issues(a, b):
            assert iss["original"] and iss["suggestion"], f"empty side in {iss}"

    # a full stop appended to a line that had none is the model finishing a
    # note fragment, not a correction — notes are mostly fragments.
    # ponytail: only the LAST word of the sentence; a missing stop mid-line
    # ("went home Then slept") is still reported.
    assert diff_issues("limit liability to a certain amount", "limit liability to a certain amount.") == []
    assert diff_issues("went home Then slept", "went home. Then slept") != []
    assert diff_issues("bekomen aber", "bekommen, aber")[0]["suggestion"] == "bekommen,"

    # adjacent edits are ONE rewrite. The word diff aligns on a shared word and
    # hands back fragments ("there house, their" -> "their", "late." -> "house;
    # they are late.") that only make sense together; merge spans whose gap is
    # whitespace. Non-adjacent spelling fixes stay separate rows.
    src5 = "There going to there house, their late."
    issues = diff_issues(src5, "They are going to their house; they are late.")
    assert [i["original"] for i in issues] == ["There", "there house, their late."], issues
    assert issues[1]["suggestion"] == "their house; they are late.", issues
    assert src5[issues[1]["start"]:issues[1]["end"]] == issues[1]["original"]
    issues = diff_issues("I recieved the pacakge", "I received the package")
    assert [i["original"] for i in issues] == ["recieved", "pacakge"], "one word apart stays separate"

    # ignored edits never become issues
    assert diff_issues("linguists analyse text", "linguists analyze text") == [], "dialect filtered"
    assert diff_issues("we don’t care", "we don't care") == [], "cosmetic filtered"
    assert diff_issues("nothing wrong", "nothing wrong") == [], "no-op"

    # --- second-opinion model: the request's `model` overrides the default for
    # that one call only (the panel's [b] key / ⌘⌥⇧S re-check with gemma4:31b).
    sent = []
    class _Resp:
        def json(self): return {"response": "Courts strike them down"}
    spellcheck_server.requests.post = lambda url, **kw: sent.append(kw["json"]) or _Resp()
    correct = spellcheck_server._load_ollama()
    correct(["Course strike them down"])
    correct(["Course strike them down"], model="gemma4:31b")
    assert [j["model"] for j in sent] == [spellcheck_server.OLLAMA_MODEL, "gemma4:31b"], sent

    # --- /event: the Obsidian plugin reports accepts/skips here; same shape as
    # the Hammerspoon SPELL lines so one grep covers both clients.
    assert event_line({"kind": "accept", "app": "Obsidian", "original": "theres", "suggestion": "there's"}) == \
        'SPELL app="Obsidian" ACCEPT "theres" → "there\'s"'
    assert event_line({"kind": "skip", "app": "Obsidian", "original": "x", "suggestion": "y"}) == \
        'SPELL app="Obsidian" SKIP "x" → "y"'

    print("test_spellcheck: all passed")


if __name__ == "__main__":
    test()
