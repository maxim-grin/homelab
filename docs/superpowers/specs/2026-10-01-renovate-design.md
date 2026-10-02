# Renovate — Design

A hosted update bot that opens a pull request when upstream releases a
newer version of something this repository pins. A small, separate piece
of work, not a sub-project of the [homelab
roadmap](2026-09-26-homelab-roadmap-design.md).

## Goal

Pins in this repository — CI tool versions, Ansible role versions, Helm
chart revisions, Terraform providers, GitHub Actions — go stale silently.
Know when one has a newer release without watching a dozen projects by
hand, and keep the bump a reviewed pull request, since here a merge is a
deploy.

Done means:

- the Renovate GitHub App runs on `maxim-grin/homelab` only, and the
  onboarding pull request (#71) has closed itself because `renovate.json5`
  is on `main`
- a Dependency Dashboard issue lists every tracked pin and its available
  update
- a newer release of a tracked pin with no companion hash opens a pull
  request without anyone asking; one with a companion hash opens it when
  the owner ticks its box in the dashboard
- no pull request merges itself
- a Renovate pull request passes CI as it arrives, apart from the hash
  failure that gate exists to catch

## Decisions

| Question | Decision |
| --- | --- |
| Who runs it | The hosted Mend Renovate Community app, free, mode "Scan and Alert", installed on this one repository. No token in the repository, no CI job, no bot credential beyond the app's own install. |
| Alternatives | Dependabot reads Actions, Terraform and pip only: not Ansible defaults, the CI `env` block or Helm `targetRevision`. Self-hosted Renovate can recompute hashes but needs a stored GitHub token and a job to maintain, for a bot that can write to a repository where a merge is a deploy. |
| Config file | `renovate.json5`, not `.json`, so the exclusion below can carry a comment pointing at its ADR. |
| Onboarding | The config ships in this repository's own pull request. Once it is on `main`, Renovate treats the repository as onboarded and closes its own #71. Nothing is pushed to the bot's branch. |
| Automerge | None, anywhere. |
| Merging | The owner squash-merges Renovate pull requests with a short Conventional subject. Everything else keeps merge commits. |
| Commit rule | The `commits` job skips pull requests authored by `renovate[bot]`: its titles (`chore(deps): update … to …`) run past the 50-character limit, and the job checks the commits on the branch, not the squash message. |
| Schedule | Mondays before 07:00 UTC. At most 3 pull requests open at once. Label `deps`. |

## What it tracks

- **Built in:** GitHub Actions (already pinned by SHA with a `# vX` comment,
  which Renovate maintains), Terraform providers and `required_version`
  constraints, `ansible/requirements.yml`, the jobboard image in its
  kustomization, and the hook revisions in `.pre-commit-config.yaml`
  (the `pre-commit` manager is opt-in, so `renovate.json5` enables it).
  The gitleaks hook's depName is `gitleaks/gitleaks`, the same as the CI
  pin, so the gated entry covers it: a gitleaks bump waits for the
  dashboard tick for both, and the hook rev has no hash to push.
- **Helm charts in Application CRs:** the built-in `argocd` manager,
  pointed at `argocd/environments/**`, reads `targetRevision` for
  cert-manager and ingress-nginx.
- **CI `env` versions and Ansible role defaults:** custom regex managers.
  Each pin carries a `# renovate: datasource=… depName=…` comment on the
  line above it, Renovate's usual convention. The comments are added to
  the pins that are on `main` when this lands. Pins added by pull
  requests still open at that time (the CI `*_SHA256` values) get
  theirs from whichever pull request merges second, or a follow-up.
  The Glance pin is not annotated yet: a follow-up adds
  `# renovate: datasource=github-releases depName=glanceapp/glance extractVersion=^v(?<version>.+)$`
  above `glance_version` after PR #65 merges; until then the gated
  `glanceapp/glance` entry is inert.
- **Not tracked:** `vault_version` (an apt package revision, not a
  release), the unpinned `ubi-minimal:latest` image, the `setup-python`
  version, which would be noise, the Argo CD `quay.io/argoproj/argocd`
  image tag in the same role's defaults, which is bumped by hand to
  match the chart, and the `ubuntu` runner image in `runs-on`.

## Prod was excluded until sub-project 2

`terraform/environments/prod` and `talos/` were never-applied scaffolding
(CLAUDE.md). Renovate's defaults would have proposed `proxmox 3.0.2-rc10`
for prod's root, quietly "fixing" the provider conflict that sub-project 2
was meant to fix on purpose, so both paths were in `ignorePaths`.

Sub-project 2 is done (#66), so the entries are removed. The three roots
now pin the same `Telmate/proxmox`, and Renovate puts one update to it in
every `versions.tf` on a single branch (checked with a dry run), so they
cannot drift apart.

## Pins with a companion hash

CI tools (`*_SHA256`), `gatus`, `orangutan`, `glance` and `traefik` pin a
checksum or digest next to the version (ADR 0017). A bare version bump
cannot pass: CI fails at `sha256sum --strict` for the tools, and an Ansible
run fails at download for the roles. These pins are gated by
`dependencyDashboardApproval`: no pull request exists until the owner
ticks the box. Then the owner pushes the new hash to the branch, using the
command documented in `docs/operations.md`.

Pins with no hash — Actions, providers, Helm charts — open on their own.

## Failure modes

| What goes wrong | What happens |
| --- | --- |
| A hash-bearing pin is bumped without its hash | CI fails (tools) or the Ansible run fails (roles). Intended; the dashboard gate makes it rare. |
| A Helm chart bump merges and breaks a sync | Argo reports the failure on its next poll; the revert is a pull request. This is every change in this repository. |
| Renovate floods the repository on first run | The cap of 3 open pull requests and the dashboard gate bound it. |
| The app is uninstalled or the repository ignored | Pins go stale again. Nothing else breaks. |

## Documentation

- ADR `docs/decisions/0023-renovate-hosted-app.md`: the hosted choice, the
  squash exception, the dashboard gate, the prod exclusion and when to
  lift it.
- `docs/operations.md`, a section **Updating a pinned version**: how a
  bump arrives, the dashboard tick, and one small table of the command for
  each kind of pin — GitHub's per-asset digest for release assets
  (`gh api repos/<owner>/<repo>/releases/tags/<tag> --jq '.assets[] |
  select(.name=="<asset>") | .digest'`), the image layer digest for Gatus,
  Traefik's published checksums file, and "nothing" for pins with no hash —
  pointing at each pin's own comment and ADR 0017 rather than copying
  them.
- `CLAUDE.md`, "Landing work": Renovate pull requests are squash-merged by
  the owner.
- Roadmap spec, sub-project 2: a "Done when" item to re-enable Renovate
  for prod and `talos/`.

## Pull requests

One pull request: `renovate.json5`, the annotation comments, the
`commits` job change, ADR 0023, and the documentation above.

## Out of scope

- A repository-wide move from merge commits to squash merges — its own
  small pull request if wanted.
- Automerge, grouping beyond Renovate's recommended presets, and
  vulnerability alerts.
- Recomputing hashes automatically, which needs self-hosted Renovate.
- Tracking `vault_version`.
