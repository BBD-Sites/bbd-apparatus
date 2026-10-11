#!/usr/bin/env python3
"""Find a sentence that tells the model to act outward (design D29, task 7.36).

  outward.py scan <allowlist> <file>...   print "file<TAB>sentence" for each hit; nothing when clean

An outward verb is send, post, book, pay, buy, email, text, publish, submit or message,
in any of its forms. A hit is a sentence that uses one as an ACTION it asks for: the verb
opens the sentence, or follows a word that makes it an instruction or a plan (to, then,
and, or, will, should, must, can, may, please, you, we, I, just, now, also). A noun
use ("the text", "a message", "an email") has an article or an adjective before it, so
it is not a hit. A sentence that refuses ("never", "not", "no", "nothing", "without",
"cannot", "do not") is not a hit either, because the refusal is the point of it.

A sentence that is a real instruction about something that is not outward (for example
"send" meaning the reply the model itself gives) goes on the allowlist, one line each:
the phrase with its spaces folded, lower case. The list is short on purpose; every line
in it is a phrase a person read and judged descriptive; a sentence that contains one passes.
"""
from __future__ import annotations

import re
import sys

BASE = ("send", "post", "book", "pay", "buy", "email", "text", "publish", "submit", "message")
FORMS = set()
for b in BASE:
    FORMS.add(b)
    FORMS.add(b + "es" if b.endswith(("sh", "s")) else b + "s")
    stem = b[:-1] if b.endswith("e") else b
    if b in ("submit",):
        stem = "submitt"
    FORMS.add(stem + "ing")
FORMS.update({"emails", "texts", "texting", "emailing", "messages", "messaging", "booking", "posting"})

LEAD = {"to", "then", "and", "or", "will", "should", "must", "can", "may", "please", "you",
        "we", "i", "just", "now", "also", "next", "first", "always", "might", "would"}
NEG = {"never", "not", "no", "nothing", "nor", "without", "cannot", "can't", "don't", "doesn't",
       "won't", "refuse", "refuses", "refused", "none", "nobody", "isn't", "aren't"}
SENT = re.compile(r"(?<=[.!?:;])\s+|\n\s*\n")
BULLET = re.compile(r"\n(?=\s*(?:[-*+>]\s|\d{1,3}[.)]\s|#{1,6}\s))")
LEADING = re.compile(r"^\s*(?:[-*+>]\s+|\d{1,3}[.)]\s+|#{1,6}\s+)+")
WORD = re.compile(r"[a-z']+")


def sentences(text: str) -> list:
    out = []
    text = re.sub(r"`[^`\n]*`", " ", text)
    text = BULLET.sub("\n\n", text)
    for raw in SENT.split(text):
        s = LEADING.sub("", raw).strip()
        if s:
            out.append(" ".join(s.split()))
    return out


def hit(sentence: str) -> bool:
    words = WORD.findall(sentence.lower())
    if any(w in NEG for w in words):
        return False
    for i, w in enumerate(words):
        if w in FORMS and (i == 0 or words[i - 1] in LEAD):
            return True
    return False


def allowlist(path: str) -> set:
    out = set()
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    out.add(" ".join(line.lower().split()))
    except OSError:
        pass
    return out


def main(argv: list) -> int:
    if len(argv) >= 3 and argv[0] == "scan":
        allowed = allowlist(argv[1])
        for path in argv[2:]:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
            for s in sentences(text):
                folded = " ".join(s.lower().split())
                if hit(s) and not any(a in folded for a in allowed):
                    print("%s\t%s" % (path, s))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
