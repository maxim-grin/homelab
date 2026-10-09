# 0023. Renovate, as the hosted app, proposes pin updates

**Status:** Accepted (2026-10-01); partly superseded by [0026](0026-uniform-apps.md)

## Context

Pins go stale silently: CI tool versions, role versions, Helm charts,
Terraform providers, GitHub Actions. A merge is a deploy here, so every
update has to stay reviewed. Several pins also carry a companion hash
(record [0017](0017-verify-lan-service-binaries-sha256.md)), which a
version bump alone leaves wrong.

## Decision

Run the hosted Mend Renovate Community app on this repository only,
configured in `renovate.json5`. No automerge. Pins with a companion hash
wait for a tick in the Dependency Dashboard issue before a PR opens. The
schedule is Mondays before 07:00 UTC, three open PRs at most.

The owner squash-merges Renovate PRs with a short Conventional subject;
the `commits` CI job skips PRs authored by `renovate[bot]`, because
Renovate's titles exceed the 50-character limit. Every other PR keeps
its merge commit.

Rejected:

- **Dependabot** cannot read Ansible defaults, the CI `env` block or
  Helm `targetRevision`.
- **Self-hosted Renovate** could recompute hashes, but needs a stored
  GitHub token and a job to run it, for a bot that could then write to a
  repository where a merge is a deploy.

**Every root is covered.** `terraform/environments/prod` was excluded
while it was never-applied scaffolding with a conflicting provider pin;
sub-project 2 made it real and fixed the pin, so the exclusion is gone.
The roots must keep the same `Telmate/proxmox` pin; Renovate puts one
update to it in every `versions.tf` on a single branch by default (a dry
run with an old pin showed one `renovate/proxmox-3.x` branch for all of
them), so no grouping rule is needed.

## Consequences

- A bump of a hash-bearing pin needs its new hash pushed to the PR
  branch by hand; the commands are in `docs/operations.md`.
- The hosted app holds write access to this repository through its
  install.
- The Talos version and schematic are pinned in `scripts/pve-bootstrap.sh`
  and `terraform/environments/prod/variables.tf`, where Renovate cannot
  see them. They are bumped by hand, together; CI fails if they differ.
- The `pre-commit` manager is opt-in and enabled, so hook revisions in
  `.pre-commit-config.yaml` are tracked. The gitleaks hook shares the
  `gitleaks/gitleaks` depName with the CI pin and is gated with it.
- A merge is a deploy for the Helm chart pins in the Application CRs
  and for the jobboard image in
  `argocd/apps/jobboard/dev/kustomization.yaml`.
- The `argocd_version` pin is the Argo CD Helm chart. The companion
  `quay.io/argoproj/argocd` image tag in the same defaults file is not
  tracked and must be bumped by hand to match when the chart's app
  version changes.
- The `argocd` manager also reads
  `argocd/environments/prod/applications/*.yaml`. Those CRs only
  reference `main` of this repository, which Renovate skips as
  `invalid-value`, so they open no PRs and are not excluded.

## Related

`docs/superpowers/specs/2026-10-01-renovate-design.md`; record
[0017](0017-verify-lan-service-binaries-sha256.md); `renovate.json5`.
