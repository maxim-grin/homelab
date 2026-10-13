# Faster CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** A PR waits only for the checks about what it changed; the
`pre-commit` job stops paying for the Ansible toolchain.

**Architecture:** One always-running workflow. A `changes` job emits one
boolean per area; each area's job has a job-level `if:`. `ansible-lint`
and `terraform fmt` move out of the `pre-commit` job into the jobs that
already own their toolchains. uv replaces pip; two caches.

**Tech Stack:** GitHub Actions, uv, pre-commit, ansible-lint, dorny/paths-filter.

**Spec:** `docs/superpowers/specs/2026-10-13-ci-path-gating-design.md`

## Global Constraints

- Workflow stays unfiltered: no `paths:` under `on:` (spec, "Decisions").
- Required checks `pre-commit`, `commits`, `terraform`, `manifests` keep
  their job names. Do not rename them.
- A push to `main` runs every job; gating is `github.event_name == 'pull_request'` only.
- Third-party actions pinned by commit SHA with a `# vX.Y.Z` comment.
- Tool versions stay in the `env:` block with `renovate:` comments.
- No check is lost: every hook or command that ran before still runs, in some job.
- Commits: Conventional, subject ≤ 50, no `Co-Authored-By`, no generated-with line.

Pins (verbatim):

| Action                | Pin                                                                      |
| --------------------- | ------------------------------------------------------------------------ |
| `dorny/paths-filter`  | `ceb8a2b8f2d89434be7ff52d3de7ec3738c5cc9d` # v4.0.3                      |
| `astral-sh/setup-uv`  | `1c37ad07a6a961277cf70c0d37d6f313000f5884` # v10.3.0                     |
| `actions/cache`       | `55cc8345863c7cc4c66a329aec7e433d2d1c52a9` # v6.1.0                      |

## Review Focus

- PR touching only `docs/` or `README.md`: every gated job `skipped`, `pre-commit` and `commits` green, PR mergeable.
- PR touching only `ansible/playbooks/*.yaml`: both `ansible-lint` and `scripts` run (runbook guard reads playbooks).
- PR touching only `.github/workflows/ci.yaml`: every job runs.
- Cache miss (new `requirements.yml` or hook config): job still passes, just slower.
- `terraform fmt` regression: a misformatted `.tf` must fail the `terraform` job, since the hook is skipped in `pre-commit`.

## File Structure

- Modify `.github/workflows/ci.yaml`: all job changes.
- Modify `docs/operations.md`: job list / CI description.
- Create `docs/decisions/0031-path-gated-ci.md`; add to `docs/decisions/README.md` index.
- `.pre-commit-config.yaml`: no change expected (skip is via `SKIP` env in CI).

---

### Task 1: Move ansible-lint and terraform fmt out of `pre-commit`; uv and caches

**Files:** Modify `.github/workflows/ci.yaml` (jobs `pre-commit`, `commits`, `terraform`; new job `ansible-lint`; `env:`).

**Interfaces:** Produces job id `ansible-lint` and the `UV_VERSION` env var; Task 2 adds `needs`/`if` to them.

- [x] Add `UV_VERSION: "0.13.0"` to `env:` with `# renovate: datasource=github-releases depName=astral-sh/uv`, and pass it to `setup-uv` as `version`.
- [x] `pre-commit` job: drop `setup-terraform` and `setup-python` (runner image has Python 3.12); add `setup-uv` with caching on; install pre-commit with `uv tool install "pre-commit==${PRE_COMMIT_VERSION}"`; add `actions/cache` for `~/.cache/pre-commit` keyed `pre-commit-${{ runner.os }}-${{ hashFiles('.pre-commit-config.yaml') }}`; run hooks with env `SKIP: ansible-lint,terraform-fmt`. Keep the gitleaks install and history-scan steps untouched. Rewrite the job's header comment to say the two hooks run in their own jobs.
- [x] `commits` job: same uv install of pre-commit (no cache needed).
- [x] New `ansible-lint` job: checkout, `setup-uv`, `uv tool install "ansible-lint==${ANSIBLE_LINT_VERSION}" --with-executables-from ansible-core` (exposes `ansible-galaxy`), `actions/cache` for `~/.ansible/collections` keyed on `hashFiles('ansible/requirements.yml')`, `ansible-galaxy collection install -r ansible/requirements.yml`, then `cd ansible && ansible-lint .` (the same command as the hook).
- [x] `terraform` job: add a step `terraform fmt -recursive -check -diff` run from `terraform/` before `init`.
- [x] Verify locally: `pre-commit run --all-files` and `python3 -c 'import yaml;yaml.safe_load(open(".github/workflows/ci.yaml"))'`; expect pass. If `actionlint` exists locally, run it.
- [x] Commit: `ops: split ansible-lint, use uv and caches`

### Task 2: `changes` job and job-level gating

**Files:** Modify `.github/workflows/ci.yaml`.

**Interfaces:** Consumes job ids from Task 1. Produces job `changes` with outputs `ansible`, `terraform`, `manifests`, `scripts` (strings `'true'`/`'false'`).

- [x] Add job `changes` (checkout not needed on PRs; `dorny/paths-filter` reads the PR file list via API, so give the job `permissions: pull-requests: read, contents: read`). Define the four filters from the spec's table, each also listing the CI-itself paths (`.github/workflows/ci.yaml`, `.pre-commit-config.yaml`, `ansible/requirements.yml`, `.tflint.hcl`). Derive the `scripts` filter by reading each `scripts/check-*.sh` and `scripts/tests/*.test.sh` for the directories it reads; record the result in the commit body.
- [x] Gate `ansible-lint`, `terraform`, `manifests`, `scripts` with `needs: changes` and `if: github.event_name != 'pull_request' || needs.changes.outputs.<area> == 'true'`. `pre-commit` and `commits` are not gated and do not need `changes`.
- [x] Replace the "No path filters…" header comment with the new rule: workflow unfiltered, jobs gated, skipped counts as pass, push to `main` runs all.
- [x] Verify: `check-yaml` hook passes; `scripts/check-runbooks.sh` passes.
- [x] Commit: `ops: gate jobs on changed paths`

### Task 3: ADR and docs

**Files:** Create `docs/decisions/0031-path-gated-ci.md`; modify `docs/decisions/README.md`, `docs/operations.md`.

- [x] ADR in the repo's format (copy structure from 0030): context with the 6m vs 1m52s numbers, decision (the spec's Decisions list, condensed), consequences (a missed filter dependency skips a check on a PR; push to `main` is the backstop; `ansible-lint` becomes a required check only when the owner adds it).
- [x] Index line in `docs/decisions/README.md`.
- [x] `README.md` "CI" section (not operations.md, which has no job list): six jobs, gating note.
- [x] Verify: `pre-commit run --all-files`, `scripts/check-runbooks.sh` pass.
- [x] Commit: `docs: add ADR 0031 for path-gated CI`

### Task 4: Prove it on the PR

**Files:** none kept; throwaway commits removed before ready.

- [x] Push. Read the first run's job list and timings with `gh run view <id> --json jobs`: all jobs run (the workflow file changed); `pre-commit` install is seconds on the second run (cache hit).
- [x] Throwaway commit touching only `docs/decisions/README.md`: expect `terraform`, `manifests`, `scripts`, `ansible-lint` skipped, `pre-commit` and `commits` run, `gh pr checks` all green.
- [x] (not run: the local `terraform fmt` hook rejects the probe commit and bypassing it is forbidden; the fmt step is the hook's own command) Throwaway commit adding a trailing space to a file under `terraform/` is rejected by `terraform fmt`: expect the `terraform` job red. Revert.
- [x] Throwaway commit touching only `ansible/playbooks/` (whitespace-safe comment): expect `ansible-lint` and `scripts` run.
- [x] Drop the throwaway commits (`git rebase -i` is unavailable; use `git reset --hard <last-real-commit>` then `git push --force-with-lease`), confirm the final run is green, record before/after times in the ADR, `gh pr ready 149`.
- [ ] Hand to owner: merge, then confirm the push-to-`main` run executes every job, and optionally add `ansible-lint` to the `protect main` ruleset's required checks.
