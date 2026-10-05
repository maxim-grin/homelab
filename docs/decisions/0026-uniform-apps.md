# 0026. Apps are uniform kustomize directories under one ApplicationSet

**Status:** Accepted (2026-10-05)

## Context

Prod's eight Applications were written eight ways: a git path for some,
a multi-source Helm Application with a `$values` ref for others; the
argocd-vault-plugin (AVP) on some and not others; namespace and
`syncOptions` set per file; chart versions in each Application's
`targetRevision`. The dev spoke (sub-project 4) needs the same apps on a
second cluster under names that do not collide, and eight near-identical
ApplicationSets would repeat every one of those differences twice.

## Decision

**One shape.** Every app is a kustomize directory
`argocd/apps/<app>/<env>/`. A Helm chart is inflated by `helmCharts:` in
that kustomization, which carries the repository, chart, version, release
name and values; Renovate reads the version through its kustomize
manager. The `$values` second source is gone.

**One renderer.** Every generated Application names the AVP
configuration management plugin (CMP). It runs
`kustomize build --enable-helm`. The sidecar claims a directory when its
parent holds a `config.yaml` (a uniform app) or when its render contains a
`<path:` placeholder. AVP runs only when the rendered output contains
`<path:`; otherwise the CMP prints the kustomize output unchanged. A
sealed Vault therefore stops only the apps that hold secrets, not every
app. Whether AVP itself would contact Vault on a placeholder-free input
is moot for the same reason, and is checked in the sidecar spike
([runbook](../runbooks/checks.md#check-the-cmp-sidecar)).

**One ApplicationSet.** `argocd/environments/prod/applications/appset.yaml`
is a matrix of a git-files generator over `argocd/apps/*/config.yaml` and
the cluster generator selecting `env: '{{.env}}'`. Each `config.yaml` is a
top-level list with one entry per env the app deploys to (`env`,
`namespace`, `createNamespace`, `serverSideApply`, optionally
`namespaceLabels`); `[]` deploys nothing. The git-files generator makes
each entry one parameter set, so the cluster selector filters
structurally. The Application is named `<cluster>-<dir>`; the directory
`nfs_provisioner` is renamed `nfs-provisioner`, because an underscore is
not a valid Application name. A `templatePatch` adds `syncOptions`
(`CreateNamespace`, `ServerSideApply`) and `managedNamespaceMetadata`
from the entry. `root-prod` and `argocd-config` stay plain Applications.

**Namespace labels are not a Namespace manifest.** ingress-nginx needs
its namespace labelled `pod-security.kubernetes.io/enforce: privileged`.
The chart's admission Jobs are PreSync hooks, which run before any
Sync-phase object, so on a fresh cluster they would run before a
`Namespace` manifest exists. Making the Namespace a hook instead would
delete it on every sync under Argo's default hook-delete policy. The
label is therefore carried as `managedNamespaceMetadata` with
`CreateNamespace`, which Argo applies before any phase.

**Retry, not waves.** Every generated Application retries (limit 10,
backoff 30s, factor 2, maximum 5m: about 37 minutes). Sync waves order
creation inside one parent's sync; the set creates its Applications
directly, so a wave on a generated Application orders nothing, and the
config files carry none. The ordering each app depends on (nfs before the
PVC users, cert-manager before its issuers, `monitoring-secrets`, which
owns the `monitoring` namespace, before the monitoring apps, the monitoring
chart's CRDs before `alerts` and `pve-exporter`) is written in each
config's comments and carried by the retry. Bootstrap consequence: all
apps start at once, early syncs fail and retry, and after a sealed-Vault
outage or slow chart pulls the retries can run out, leaving an app
`Sync failed` until the operator syncs it by hand
([runbook](../runbooks/checks.md#sync-an-application-by-hand)).

**The set is protected.** Deleting an ApplicationSet deletes every
generated Application, and their `resources-finalizer` then deletes the
workloads. Three guards: `applicationsSync: create-update` (the generator
never deletes an Application, so an empty or broken generator removes
nothing), `preserveResourcesOnDeletion: true` (if the set goes anyway, the
Applications go but their resources stay), and the annotation
`argocd.argoproj.io/sync-options: Prune=false,Delete=false` so `root-prod`
never prunes the set. Retiring an app is a deliberate delete of its
generated Application, then removal of its config entry
([runbook](../runbooks/checks.md#retire-an-app-from-the-set)).

**Rollout adopts in place.** The new `prod-<dir>` Application takes over
the live resources of the old one. Before a rollout PR merges, the
operator removes the old Application's `resources-finalizer`, so
`root-prod` pruning it deletes the Application only and nothing is
recreated or reissued
([runbook](../runbooks/checks.md#roll-an-app-into-the-set)). Apps move
in staged PRs, each verified before the next.

**The hub reads both KV trees.** `argocd-read-prod` reads `kv-prod/` and
`kv-dev/` (`extra_kv_mounts`), because the hub's AVP will render the
spokes' apps. A spoke's policy still reads only its own tree.

**The Prometheus receiver Ingress is write-only.** `prometheus.mgryn.cc`
exposes `/api/v1/write` (path type `Exact`) with TLS and basic auth, the
credentials in Vault. Nothing else of Prometheus is reachable through it.

**Helm hooks are expected to keep working.** Kustomize keeps the
`helm.sh/hook` annotations when it inflates a chart, and Argo maps them to
its hook phases for any source, not only Helm ones. That is the
expectation, not a proven fact: it is confirmed at the cert-manager and
ingress-nginx rollouts.

The AppProject gains destinations by cluster name for `prod` and `dev`; a
destination for a cluster not yet registered is harmless.

Rejected:

- **Eight per-app ApplicationSets**: the per-app differences would be
  repeated per set, and again for every environment.
- **Native Helm multi-source with `templatePatch`**: keeps two rendering
  paths (Helm sources and git paths) and a second AVP story; the set's
  template would have to switch source shape per app.
- **Umbrella charts**: a chart of charts per app, with its own lock file
  and values plumbing, to do what `helmCharts:` does in one stanza.
- **A `Namespace` manifest for the labels**: ordering against PreSync
  hooks, above.
- **Sync waves**: they do nothing for set-generated Applications.
- **Delete-and-recreate rollout**: reissues certificates against Let's
  Encrypt's five-per-week limit and rebuilds state; it is the fallback,
  not the plan.

## Consequences

- Adding an app, or an environment, is adding a directory and a config
  entry. The render check (`scripts/check-appsets.sh`, run by
  `scripts/check-manifests.sh`) expands the set and fails on a duplicate
  name, a selector that matches no cluster, a destination that names no
  registered cluster, or a misplaced template key.
- Every app now passes through the CMP: if the sidecar is down, nothing
  renders. A sealed Vault shows as `Unknown` only on apps with
  placeholders.
- A config entry removed does not remove the Application: retiring is a
  manual step.
- Bootstrap relies on the retry and may need one manual sync.
- `kustomize build --enable-helm` writes `charts/` under the app
  directory (gitignored) and pulls from the chart repository on every
  render; a slow pull counts against the repo-server's exec timeout.
- A misplaced key in the template is ignored silently by Argo, so the
  render check stays strict.
- Dev's Applications and overlays are unchanged until sub-project 4.

## Related

`docs/superpowers/specs/2026-10-05-uniform-apps-design.md`; records
[0004](0004-secrets-in-vault-via-avp.md),
[0011](0011-vault-on-its-own-vm.md),
[0023](0023-renovate-hosted-app.md),
[0024](0024-hub-in-prod.md).
