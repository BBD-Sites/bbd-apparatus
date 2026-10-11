#!/usr/bin/env python3
"""The reading-level grader the Stop gate runs on every reply (design D24): pure
python, no network, nothing to install.

  readability.py grade <file>                     print the text's grade level, one number
  readability.py check <file> [--ceiling N] [--limit K]
                                                  print nothing when the text is at or
                                                  under the ceiling; else print "grade<TAB>
                                                  ceiling" on the first line and then the hardest
                                                  sentences, worst first, one per line
                                                  as "grade<TAB>sentence"

The grade is the Flesch-Kincaid grade level: 0.39 * (words per sentence) + 11.8 *
(syllables per word) - 15.59. A sentence is graded the same way on its own words. A
reply is over the ceiling when its whole text grades above CEILING_REPLY (five) and at
least one sentence of MIN_WORDS words or more grades above it too; a short sentence is
never quoted, because a short sentence is not what a reader stumbles on.

A score is a flag, never a target (the readable-output requirement): the caller quotes
the sentences and the writer cuts the idea or says it in plainer words, and the grader
says nothing about how. Not read: fenced code, inline code, the lines after a line that
is only `---` (the identifiers under the closing), links' addresses, and any token that
is a path, an address, a handle or an identifier (it has a slash, an underscore, an at
sign, a colon or a digit mixed with letters), because those are names, not prose.

The ceilings are the two constants below, his to change (D36): five for what the person
reads in a reply, three for copy their own customers read. Every command exits 0.
"""
from __future__ import annotations

import re
import sys

CEILING_REPLY = 5.0
CEILING_COPY = 3.0
# A sentence shorter than this is never quoted.
MIN_WORDS = 8
# The most sentences a check quotes.
LIMIT = 5
SENTENCE_MAX = 300

FENCE = re.compile(r"```.*?```", re.S)
UNCLOSED_FENCE = re.compile(r"```.*$", re.S)
INLINE_CODE = re.compile(r"`[^`\n]*`")
LINK = re.compile(r"\[([^\]\n]*)\]\([^)\n]*\)")
URL = re.compile(r"https?://\S+|www\.\S+")
WORD = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)*|\d+(?:[.,]\d+)*")
ABBREV = re.compile(r"\b(e\.g|i\.e|etc|vs|approx)\.", re.I)
SPLIT = re.compile(r"(?<=[.!?])[\"')\]]*\s+(?=[\"'(\[]?[A-Z0-9])|\n+")
LEAD = re.compile(r"^\s*(?:[-*+>]\s+|\d{1,3}[.)]\s+|#{1,6}\s+)+")
NAMEISH = re.compile(r"[/\\_@:]|(?=.*\d)(?=.*[A-Za-z])")


def prose(text: str) -> str:
    """The text a reader reads: no code, no trailer, no addresses."""
    out = []
    for line in text.splitlines():
        if line.strip() == "---":
            break
        out.append(line)
    text = "\n".join(out)
    text = FENCE.sub(" ", text)
    text = UNCLOSED_FENCE.sub(" ", text)
    text = INLINE_CODE.sub(" ", text)
    text = LINK.sub(r"\1", text)
    text = URL.sub(" ", text)
    return text.replace("**", "").replace("__", "")


def sentences(text: str) -> list:
    text = ABBREV.sub(lambda m: m.group(1).replace(".", ""), prose(text))
    found = []
    for part in SPLIT.split(text):
        part = LEAD.sub("", part or "").strip()
        if part:
            found.append(part)
    return found


def words(sentence: str) -> list:
    """The words of a sentence that are prose: names and identifiers are left out."""
    kept = []
    for token in sentence.split():
        if NAMEISH.search(token):
            continue
        kept.extend(WORD.findall(token))
    return kept


def syllables(word: str) -> int:
    w = re.sub(r"[^a-z]", "", word.lower())
    if not w:
        return 1  # a number reads as one beat
    count = len(re.findall(r"[aeiouy]+", w))
    # A silent final e (made, site) and the silent ending of -es and -ed (makes, moved).
    if w.endswith("e") and not w.endswith(("le", "ee", "ye")) and count > 1:
        count -= 1
    elif w.endswith(("es", "ed")) and not w.endswith(("ses", "zes", "ces", "ges", "ted", "ded")) and count > 1:
        count -= 1
    return max(1, count)


def grade_of(word_count: int, syllable_count: int, sentence_count: int = 1) -> float:
    if word_count <= 0 or sentence_count <= 0:
        return 0.0
    return 0.39 * (word_count / sentence_count) + 11.8 * (syllable_count / word_count) - 15.59


def grade_sentence(sentence: str) -> tuple:
    """(grade, word count) for one sentence."""
    ws = words(sentence)
    return grade_of(len(ws), sum(syllables(w) for w in ws)), len(ws)


def grade_text(text: str) -> float:
    ws_total = syl_total = 0
    sents = 0
    for s in sentences(text):
        ws = words(s)
        if not ws:
            continue
        sents += 1
        ws_total += len(ws)
        syl_total += sum(syllables(w) for w in ws)
    return grade_of(ws_total, syl_total, sents)


def check(text: str, ceiling: float = CEILING_REPLY, limit: int = LIMIT) -> tuple:
    """(overall grade, [(sentence grade, sentence)]) with the list empty when the text
    is at or under the ceiling; worst sentence first, at most LIMIT of them."""
    overall = grade_text(text)
    if overall <= ceiling:
        return overall, []
    hard = []
    for s in sentences(text):
        g, n = grade_sentence(s)
        if n >= MIN_WORDS and g > ceiling:
            hard.append((g, s))
    hard.sort(key=lambda gs: -gs[0])
    return overall, hard[:limit]


def quote(sentence: str) -> str:
    one = " ".join(sentence.split())
    if len(one) > SENTENCE_MAX:
        one = one[:SENTENCE_MAX].rstrip() + " ..."
    return one


def main(argv: list) -> int:
    if len(argv) == 2 and argv[0] == "grade":
        with open(argv[1], encoding="utf-8", errors="replace") as f:
            print("%.1f" % grade_text(f.read()))
        return 0
    if len(argv) >= 2 and argv[0] == "check":
        ceiling, limit, rest = CEILING_REPLY, LIMIT, argv[2:]
        while len(rest) >= 2:
            if rest[0] == "--ceiling":
                ceiling = float(rest[1])
            elif rest[0] == "--limit":
                limit = int(rest[1])
            rest = rest[2:]
        with open(argv[1], encoding="utf-8", errors="replace") as f:
            overall, hard = check(f.read(), ceiling, limit)
        if hard:
            print("%.1f\t%g" % (overall, ceiling))
            for g, s in hard:
                print("%.0f\t%s" % (g, quote(s)))
        return 0
    print("usage: readability.py grade FILE | check FILE [--ceiling N] [--limit K]", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - a launcher must exit 0 whatever happens
        print("readability: %s" % type(exc).__name__, file=sys.stderr)
        sys.exit(0)
