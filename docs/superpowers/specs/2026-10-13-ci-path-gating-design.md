# Faster CI: path-gated jobs, uv, caches

Status: draft for review. Touches `.github/workflows/ci.yaml` and
`.pre-commit-config.yaml`; no cluster, Terraform or Ansible change.

## Goal

A pull request that changes one thing should wait only for the checks
about that thing. Run 38352758709 (the merge of a jobboard version bump)
took 6 minutes, 4m49s of it in the `pre-commit` job's install step
(`pip install` of pre-commit and ansible-lint plus `ansible-galaxy
collection install`, nothing cached). The same job took 1m52s on the PR
run: the install step varies by minutes with Galaxy's speed. Every other
job takes 15-30s.

Success: a PR touching only `argocd/apps/jobboard/**` finishes in about
30s with every required check green; a PR touching `ansible/**` finishes
in about 1 minute; no check that should have run is skipped.

## Decisions

- **Path gating happens inside the workflow, never on it.** The workflow
  keeps running on every PR and push. A `changes` job computes which
  areas a PR touched, and each area's job carries a job-level `if:`.
  A job skipped by `if:` counts as passing for a required check; a
  workflow skipped by `paths:` leaves its checks pending and blocks the
  merge (the reason the old header comment said "no path filters").
- **The ruleset keeps `terraform` and `manifests` required.** Skipped
  means pass, a failing run still blocks. Dropping them from the ruleset
  would make a real failure mergeable and buy no speed. The new
  `ansible-lint` job is added to the ruleset by the owner after merge.
- **A push to `main` runs everything.** Gating applies to pull requests
  only. The merge run is the backstop for a filter that missed a
  dependency, and with caches it costs about a minute.
- **Changes to CI itself run everything.** A change to
  `.github/workflows/ci.yaml`, `.pre-commit-config.yaml`,
  `ansible/requirements.yml` or `.tflint.hcl` turns every filter on.
- **`ansible-lint` and `terraform fmt` leave the `pre-commit` job.** They
  need the Ansible toolchain and the terraform binary, which the other
  hooks do not. The `pre-commit` job sets `SKIP=ansible-lint,terraform-fmt`;
  a new `ansible-lint` job runs ansible-lint, and the `terraform` job runs
  `terraform fmt -recursive -check`. Locally both hooks stay as they are,
  so the commit-time experience is unchanged.
- **uv replaces pip.** `astral-sh/setup-uv` with its cache; pre-commit and
  ansible-lint install with `uv tool install` at the versions already
  pinned in `env:`.
- **Caches, keyed on the file that pins them:** `~/.ansible/collections`
  on `ansible/requirements.yml`; `~/.cache/pre-commit` on
  `.pre-commit-config.yaml`. Pinned versions make both exact.
- **Third-party actions are pinned by commit SHA**, as the others are.
  Renovate keeps them current.

## Filters

| Job            | Runs on a PR when the diff touches                                                  |
| -------------- | ----------------------------------------------------------------------------------- |
| `pre-commit`   | always (cheap: file hooks, shellcheck, gitleaks)                                    |
| `commits`      | always (unchanged)                                                                  |
| `ansible-lint` | `ansible/**`                                                                        |
| `terraform`    | `terraform/**`, `.tflint.hcl`                                                       |
| `manifests`    | `argocd/**`, `scripts/check-manifests.sh`, `scripts/check-appsets.sh`               |
| `scripts`      | `scripts/**`, `docs/runbooks/**`, `ansible/playbooks/**`, `ansible/inventories/**`  |

Plus the CI-itself paths above, which select every row.

The `scripts` job runs the runbook guard, which reads playbooks and
inventories, so those belong in its filter. This is the one dependency
most likely to be missed; the plan lists every `scripts/*` check's inputs
and the filter is derived from them, not guessed.

## Non-goals

- Splitting `manifests` per environment, or sharding `terraform` per root.
  Both jobs already finish in under 30s.
- Dropping the `push: main` run. Kept, as the safety net.
- Changing what any check verifies.

## Verification

- `pre-commit run --all-files` and `scripts/check-runbooks.sh` pass.
- On the PR, one commit per area (argocd only, ansible only, docs only)
  and the run's job list read each time: the right jobs run, the rest
  show `skipped`, required checks all resolve.
- A push-to-`main` run shows every job executing. Checked after the
  owner merges, since an agent cannot trigger it.
- Wall-clock before and after is recorded in the ADR.

## Documentation

ADR 0031 (path-gated CI, with the skipped-counts-as-pass rationale and
the push-to-`main` exception). The `ci.yaml` header comment about path
filters is rewritten to match. `docs/operations.md` is updated where it describes
the job list.
