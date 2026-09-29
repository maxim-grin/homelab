#!/usr/bin/env python3
"""Check a commit message against CLAUDE.md's rules.

Runs as a commit-msg hook (pre-commit passes the message file) and in CI's
`commits` job, one message at a time. Conventional Commits' type and format
are conventional-pre-commit's job; this checks what it does not:

- the subject is at most 50 characters
- a blank line separates the subject from the body
- body lines are at most 72 characters, except lines holding a URL, which
  cannot be wrapped
- no Co-Authored-By trailer and no "Generated with" line: agents working here
  do not sign commits

Merge commits and fixup!/squash!/amend! subjects are git's own wording and
are skipped.
"""

import re
import sys

SUBJECT_MAX = 50
BODY_MAX = 72

# `git commit -v` appends the diff below this line; git strips it, and so do we.
SCISSORS = "# ------------------------ >8 ------------------------"

SKIP_SUBJECT = re.compile(r"^(Merge |fixup! |squash! |amend! )")
ATTRIBUTION = re.compile(
    r"^\s*co-authored-by:|^\W*generated with\b", re.IGNORECASE
)


def message_lines(text):
    """The lines git keeps: before the scissors, without # comments."""
    lines = []
    for line in text.splitlines():
        if line.startswith(SCISSORS):
            break
        if line.startswith("#"):
            continue
        lines.append(line.rstrip())
    while lines and not lines[0]:
        lines.pop(0)
    return lines


def problems(lines):
    if not lines:
        return []
    subject = lines[0]
    if SKIP_SUBJECT.match(subject):
        return []

    found = []
    if len(subject) > SUBJECT_MAX:
        found.append(
            f"subject is {len(subject)} characters, the limit is {SUBJECT_MAX}:"
            f"\n    {subject}"
        )
    if len(lines) > 1 and lines[1]:
        found.append("line 2 must be blank, separating the subject from the body")
    for number, line in enumerate(lines[1:], start=2):
        if len(line) > BODY_MAX and "://" not in line:
            found.append(
                f"line {number} is {len(line)} characters, the limit is"
                f" {BODY_MAX}:\n    {line}"
            )
        if ATTRIBUTION.search(line):
            found.append(
                f"line {number} is an attribution line, which CLAUDE.md"
                f" forbids:\n    {line}"
            )
    return found


def main(argv):
    if len(argv) != 2:
        print(f"usage: {argv[0]} <commit message file>", file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        found = problems(message_lines(f.read()))
    for problem in found:
        print(f"commit message: {problem}", file=sys.stderr)
    if found:
        print(
            "A rejected commit keeps its message in .git/COMMIT_EDITMSG;"
            " `git commit -e -F .git/COMMIT_EDITMSG` reopens it.",
            file=sys.stderr,
        )
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
