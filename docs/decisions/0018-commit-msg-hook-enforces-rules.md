# 0018. Commit rules enforced by a commit-msg hook, not by review

**Status:** Accepted (2026-09-29)

## Context

CLAUDE.md's commit rules (Conventional Commits, subject ≤ 50 characters,
body ≤ 72, no `Co-Authored-By` or generated-with line) were enforced only
by review. Nearly every session up to this point had rewritten local
history to fix a subject that was too long or an attribution trailer that
slipped through.

## Decision

Add `scripts/check-commit-msg.py` as a `commit-msg` hook: it rejects a
subject over 50 characters, a body line over 72 unless it holds a URL, a
missing blank line after the subject, or a `Co-Authored-By`/`Generated
with` line, skipping merge commits and `fixup!`/`squash!`/`amend!`
subjects. CI's `commits` job runs it by id (and the existing
conventional-commit hook) rather than every no-stage hook once per commit.

## Consequences

The rule now fails the commit itself, not just the PR review. It surfaced
that this workstation's own clone had never run `pre-commit install`, so
even the pre-existing Conventional Commits check had never actually run
locally — a clone missing `.git/hooks/commit-msg` needs `pre-commit
install` run once. Verified against the last 60 non-merge commits on
`main`, all of which passed the new hook.

## Related

[#60](https://github.com/maxim-grin/homelab/pull/60) "ops: check commit
message length in a hook"; `scripts/check-commit-msg.py`; CLAUDE.md
"Commits".
