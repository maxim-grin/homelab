# 0031. CI jobs run only for the areas a pull request touches

**Status:** Accepted (2026-10-13)

## Context

The merge run of a jobboard version bump took 6 minutes. 4m49s of it was
the `pre-commit` job's install step: `pip install` of pre-commit and
ansible-lint plus `ansible-galaxy collection install`, nothing cached. The
same job took 1m52s on the PR run; the step varies by minutes with
Galaxy's speed. Every other job takes 15-30s. A one-line version bump
paid for the Ansible toolchain it never touched.

`main` requires `pre-commit`, `commits`, `terraform` and `manifests`. A
`paths:` filter on the workflow would leave those checks pending for a PR
that matches none of it, and block the merge.

## Decision

**The workflow runs on every PR and push; jobs skip themselves.** A
`changes` job runs `dorny/paths-filter` on pull requests and outputs one
flag per area. `ansible-lint`, `terraform`, `manifests` and `scripts` carry
a job-level `if:` on their flag. A job skipped by `if:` counts as passing
for a required check, so the ruleset is unchanged and a failing run still
blocks the merge.

- **A push to `main` runs every job.** Gating applies to pull requests
  only; the merge run is the backstop for a filter that missed a
  dependency.
- **A change to CI itself selects every area:** `ci.yaml`,
  `.pre-commit-config.yaml`, `ansible/requirements.yml`, `.tflint.hcl`.
- **`ansible-lint` and `terraform fmt` leave the `pre-commit` job**
  (`SKIP=ansible-lint,terraform-fmt`). `ansible-lint` becomes its own job;
  `terraform fmt -check` joins the `terraform` job. Locally both hooks are
  unchanged.
- **uv replaces pip,** and `~/.ansible/collections` and
  `~/.cache/pre-commit` are cached, keyed on the files that pin them.

## Consequences

Measured on the PR (#149) and two throwaway probe PRs: with warm caches
the whole run takes about 40s, `pre-commit` 12s and `ansible-lint` 22s
(cold: 52s and 43s). A docs-only PR ran `pre-commit` and `commits` and
skipped the other four; an `ansible/playbooks`-only PR ran `ansible-lint`
and `scripts`. Before: 1m52s to 6m.

- A PR that touches only `argocd/apps/<app>/` runs `pre-commit`, `commits`
  and `manifests`; one that touches only docs runs `pre-commit` and
  `commits`.
- The `scripts` job reads playbooks, inventories, runbooks and the prod
  `variables.tf`, so its filter lists them. A new input to any `scripts/`
  check must be added to the filter, or a PR can skip a check it should
  have run until the push to `main`.
- `ansible-lint` is a new job name. It is required only once the owner
  adds it to the `protect main` ruleset.
