# 0023. Renovate, as the hosted app, proposes pin updates

**Status:** Accepted (2026-10-01)

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

**Excluded until sub-project 2:** `terraform/environments/prod` and
`talos/`, never-applied scaffolding. Renovate's defaults would silently
"fix" prod's conflicting provider pin. Remove both `ignorePaths`
entries in `renovate.json5` when roadmap sub-project 2 is done.

## Consequences

- A bump of a hash-bearing pin needs its new hash pushed to the PR
  branch by hand; the commands are in `docs/operations.md`.
- The hosted app holds write access to this repository through its
  install.
- The Glance pin is not annotated yet. A follow-up adds
  `# renovate: datasource=github-releases depName=glanceapp/glance extractVersion=^v(?<version>.+)$`
  above `glance_version` after PR #65 merges; until then the gated
  `glanceapp/glance` entry is inert.
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
