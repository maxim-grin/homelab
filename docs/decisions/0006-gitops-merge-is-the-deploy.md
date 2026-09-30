# 0006. Agents land Kubernetes changes only through a merged pull request

**Status:** Accepted (2026-09-15)

## Context

ArgoCD's app-of-apps (`root-dev`) syncs `main` from GitHub, not any local
working copy. A commit, a pushed branch, or an open pull request are all
invisible to the cluster until `main` on GitHub actually changes — the
single most common way an "applied" change appeared to do nothing.

## Decision

Work lands on `main` only through a GitHub pull request opened with `gh`;
no local merges, no direct pushes. An agent's job ends at the open PR — the
repository owner reviews and merges, because the merge is the deploy and
the merge button stays with whoever will watch the cluster roll. Once a
brainstorming spec is committed, the branch is pushed and a **draft** PR
opened immediately, so the design is reviewable before any plan or code
exists; the plan and implementation land in the same draft, marked ready
with `gh pr ready` once finished.

## Consequences

Every change is reviewable on GitHub before it reaches the cluster, and
`git log` on `main` is a true deploy history. It costs a review step for
every change, including docs-only ones, and it means a plan's "merge and
push `main`" instruction now means "merge the PR" — an easy phrase to get
wrong when copying old plans forward.

## Related

CLAUDE.md "Landing work"; [#13](https://github.com/maxim-grin/homelab/pull/13)
"docs: land work through pull requests";
[#45](https://github.com/maxim-grin/homelab/pull/45) "docs: open a draft pr
when a spec is committed".
