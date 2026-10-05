# Uniform Apps — Design

Prerequisite to roadmap sub-project 4
([dev spoke](2026-10-05-dev-spoke-design.md)). Everything in sub-4 that
touches only prod moves here; sub-4 keeps the dev work and its spec and
plan are revised after this lands.

## Problem

Prod's eight Applications are written eight ways:

- git path (`nfs`, `alerts`, `cert-manager-issuers`, `monitoring-secrets`,
  `pve-exporter`) versus multi-source Helm with a `$values` git ref
  (`cert-manager`, `ingress-nginx`, `monitoring`)
- AVP plugin on some, none on others
- namespace, sync wave and `syncOptions` (kube-prometheus-stack needs
  server-side apply for its CRDs) set per file
- Helm chart versions live in each Application's `targetRevision`

Sub-4 needs the same apps on two clusters under names that do not
collide. Eight near-identical ApplicationSets would repeat these
differences twice over. One uniform shape makes one ApplicationSet enough,
and adding an app, or an environment, becomes adding a directory.

## Decisions

| Question | Decision |
| --- | --- |
| Shape | Every app is a kustomize directory `argocd/apps/<app>/<env>/`. Helm charts are inflated with `helmCharts:` |
| Rendering | One path: the existing argocd-vault-plugin (AVP) CMP runs every app, `kustomize build --enable-helm` |
| Per-app facts | `argocd/apps/<app>/config.yaml`: a top-level list with one entry per env the app is deployed to (`env`, namespace, sync wave, `createNamespace`, `serverSideApply`); an empty list deploys nothing |
| Generator | One ApplicationSet: a matrix of the cluster generator (label `env`) and a git-files generator over `config.yaml` |
| Names | `<cluster>-<directory>`, so `prod-nfs-provisioner` and `prod-kube-prometheus-stack`. `nfs_provisioner` is renamed `nfs-provisioner`, since an underscore is not a valid name. Nothing references the old Application names. Prod's Applications are deleted and recreated; prod holds no valuable data |
| Plain Applications | `root-prod` and `argocd-config` stay plain |
| Scope | Prod only. Dev's Application CRs and overlays stay as they are until sub-4 |
| Chart versions | Move into each `kustomization.yaml`; Renovate switches from its Argo manager to its kustomize manager for them |

Also moved here from sub-4, because they touch only prod:

- Prod ArgoCD's Vault policy also reads `kv-dev/`. The hub reads both KV
  trees; a spoke reads only its own.
- Prometheus receiver ingress at `prometheus.mgryn.cc` with TLS and basic
  auth, credentials in Vault (`kv-prod/monitoring/remote-write`, field
  `htpasswd`; `kv-dev/monitoring/remote-write` holds the plain pair for
  the sender sub-4 adds).
- Cluster Secret for prod (`name: prod`, `env=prod`, in-cluster), and
  AppProject destinations by cluster name for `prod` and `dev`. A
  destination for a cluster not yet registered is harmless.

## Design

**Layout.**

- `argocd/apps/<app>/<env>/kustomization.yaml` for every app; plain-manifest
  apps already have it.
- Helm apps move their chart repository, chart name, version, release name
  and values into that kustomization (`helmCharts:`, `includeCRDs: true`).
  The `$values` second source goes away.
- `argocd/apps/<app>/config.yaml` per app. It carries only what differs
  between apps: one entry per env it is deployed to, each with namespace, sync wave and `syncOptions`. The git-files generator turns each list entry into one parameter set, so the cluster generator can select `env: '{{.env}}'` and the filtering is structural.

**The set.**

- Matrix generator: clusters selected by the `env` label, times a
  git-files generator reading `argocd/apps/*/config.yaml`, keeping the
  pairs whose config lists the cluster's env.
- Template: name `{{cluster}}-{{app}}`, project `homelab`, one source on
  `argocd/apps/{{app}}/{{env}}` with `plugin: argocd-vault-plugin`,
  automated sync with prune and selfHeal, the resources finalizer,
  `CreateNamespace`, wave and `syncOptions` from the config.

**The CMP.**

- The plugin command runs `kustomize build --enable-helm`. That needs a
  helm binary in the CMP sidecar. Checked first; if absent, the sidecar
  image or an init-container install is part of this work.
- Apps with no placeholders pass through AVP unchanged. AVP must not
  contact Vault when there are none; if it does, a sealed Vault breaks
  every app, not only the ones with secrets. Checked, and the result
  goes in the plan.

**Hub-side changes** as listed above, each in its own commit.

## Verification

No test suite, so each step is checked on the thing itself.

- `scripts/check-manifests.sh` renders every app the way the CMP does
  (`kustomize build --enable-helm`), schema-checks it, and, for the set,
  expands the generators and asserts: each Application name is unique,
  every set selector matches at least one cluster, destinations name a
  registered cluster, and a misplaced key under `template.spec` fails the
  check.
- Per Helm chart (`cert-manager`, `ingress-nginx`, `kube-prometheus-stack`):
  the rendered kustomize output is compared with `helm template` of the
  same chart and values. Differences are accounted for in the plan:
  Helm hooks (plain resources under kustomize, since Argo only maps them
  for Helm sources), CRDs, and server-side apply for the large CRDs.
- Prod rollout, staged as a runbook entry: `alerts` first, then
  cert-manager and its issuers against `letsencrypt-staging`, then
  `nfs`, `ingress-nginx`, `monitoring-secrets`, `monitoring`,
  `pve-exporter` in sync-wave order. After each: `kubectl get pods -A`
  and the thing itself (`curl` with the right `Host:`, `showmount -e`).
  Vault must be unsealed first.
- Receiver: an unauthenticated write returns 401; an authenticated one
  larger than the default 1m body is not 413.

## Risks

- **Helm hooks become plain resources.** A hook Job that was transient
  becomes permanent, or runs on every sync. Found by the per-chart
  comparison, fixed in the kustomization (patch or disable the hook).
- **Let's Encrypt rate limit.** Recreating cert-manager reissues the
  `argocd.mgryn.cc` certificate; five duplicates a week. Staging first.
- **One plugin for everything.** If the CMP sidecar is down or Vault is
  sealed in a way AVP notices, every app stops rendering, not only the
  secret-bearing ones. The sealed-Vault check above is the guard; the
  rule that a sealed Vault shows as `Unknown` with health `Healthy`
  still applies.
- **A set matching nothing makes an app vanish silently.** The render
  check asserts every set yields at least one Application.
- **A misplaced key in a template is ignored silently** (as
  `managedNamespaceMetadata` was); the check stays strict.
- **Renovate silently loses the charts** if its kustomize manager is not
  configured for `helmCharts:`; the first Renovate run after merge is
  checked for chart PRs.

## Documentation

- ADR 0026: apps are uniform kustomize directories under one
  ApplicationSet, and the hub reads both KV trees. Amends ADRs 0004,
  0011, 0023 (Renovate) and 0024. Sub-4's own ADR is therefore 0027.
- README table and Mermaid diagram; `docs/rebuild.md` where it names
  Application files; `docs/runbooks/` gets the prod rollout entry and the
  Vault-policy re-run; CLAUDE.md's layout section and the AppProject note.

## Out of scope

- Anything dev-specific: the dev cluster Secret, the registration
  playbook, dev overlays, agent-mode Prometheus, the cutover and
  rebuild. All stay in sub-4.
- Moving the plain Applications `root-prod` and `argocd-config` into the
  set.
- A kind-based CI cluster, Molecule, and `conftest` policies.

## Effect on sub-4

After this merges, the dev-spoke spec and plan lose: the prod
ApplicationSet conversion, the Vault policy widening, the receiver
ingress, the prod cluster Secret and the AppProject destinations. What is
left is the dev half. They are revised on their own branch afterwards, not
here.
