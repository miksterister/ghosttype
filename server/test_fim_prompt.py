# Pure unit test for the FIM prompt builder. Run: ~/.venvs/ghosttype/bin/python server/test_fim_prompt.py
from ghosttype_server import build_fim_prompt

def test():
    assert build_fim_prompt("a", "b") == "<|fim_prefix|>a<|fim_suffix|>b<|fim_middle|>", "basic"
    assert build_fim_prompt("pre ", "") == "<|fim_prefix|>pre <|fim_suffix|><|fim_middle|>", "empty suffix"
    assert build_fim_prompt("", "") == "<|fim_prefix|><|fim_suffix|><|fim_middle|>", "both empty"
    # stop_at: early-stop decision over accumulated streamed text
    from ghosttype_server import stop_at
    assert stop_at("hello wor") is None, "no stop condition yet"
    assert stop_at("hello\nworld") == "hello", "newline stops, keeps first line"
    assert stop_at("\nx") == "", "leading newline stops with empty text"
    assert stop_at("one two three four five", 4) == "one two three four", "word cap"
    assert stop_at("one two three four", 4) is None, "4th word not completed yet"
    assert stop_at("one two three four ", 4) == "one two three four", "trailing space completes 4th"
    assert stop_at("one two\nthree", 4) == "one two", "newline wins under the cap"
    assert stop_at("a b\n", 1) == "a", "cap wins inside the pre-newline text"
    assert stop_at("one  two   three ", 3) == "one  two   three", "internal spacing preserved"
    # Control tokens (<|fim_pad|>, <|endoftext|>, ...) leak into prose FIM
    # output when the model has nothing to say — never valid ghost text
    assert stop_at("hello<|fim_pad|>junk") == "hello", "control token stops"
    assert stop_at("<|fim_pad|><|fim_pad|>x") == "", "leading control token yields empty"
    assert stop_at("one two three four five<|fim_pad|>", 4) == "one two three four", "word cap still applies before control token"
    assert stop_at("hi there\nrest<|endoftext|>") == "hi there", "newline still wins inside head"
    # trim_suffix_echo: never re-suggest the text right of the caret
    from ghosttype_server import trim_suffix_echo as t
    assert t("is Paris. The capital", " is Paris.") == "", "echo of whole suffix"
    assert t("before the end", " before the end of the quarter.") == "", "echo of suffix head"
    assert t("soon, before the", " before the end") == "soon,", "continuation then echo"
    assert t("move it to the", " the office") == "move it to", "single-word overlap at the seam"
    assert t("to production", " before the end") == "to production", "unrelated kept"
    assert t("the end", " the beginning") == "the end", "partial match that diverges is kept"
    assert t("Before The End", " before the end.") == "", "case-insensitive"
    assert t("anything", "") == "anything", "no suffix"
    assert t("anything", "\nnext line") == "anything", "suffix on a later line ignored"
    assert t("don't know", " don't know why") == "", "apostrophes are one word"
    # has_content: a suggestion with no letter or digit is never worth drawing.
    # The junk list is real output from the live log, not invented.
    from ghosttype_server import has_content
    for junk in (".", "?", ")", ":(:(:(:(:(:(:(:(", "", "   ", "...", "-- "):
        assert not has_content(junk), f"should reject {junk!r}"
    # "e." is a genuine mid-word completion of "sourc|e." — a length or
    # repetition rule would have eaten it. Only alnum content decides.
    for good in ("e.", "apps.", "Berlin.", "json.load(f)", "ility.", "nk?", "2"):
        assert has_content(good), f"should keep {good!r}"
    # finish: the model's leading space is the separator after a finished word
    from ghosttype_server import finish
    assert finish(" at the park.", "we should meet", "") == " at the park.", "space kept after a word"
    assert finish("thing.", "bought some", "") == "thing.", "mid-word stays glued"
    assert finish(" at the", "we should meet ", "") == "at the", "no double space after typed space"
    assert finish(" is Paris.", "The capital", " is Paris.") == "", "suffix echo still trimmed"
    assert finish(" .", "done", "") == "", "punctuation-only still dropped"

    print("test_fim_prompt: 46 passed")

if __name__ == "__main__":
    test()

