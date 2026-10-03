# 0024. The hub platform runs in prod; dev is a spoke

**Status:** Accepted (2026-10-03)

## Context

Two clusters would each run their own ArgoCD, and later their own
Grafana. On a 31G host that duplicates about 6G of platform workloads.
The roadmap puts the platform in one place: the Talos prod cluster, with
dev reduced to a workload spoke. `shared` holds `nfs-01`, `vault-02` and
the LAN LXCs; it is not a cluster and cannot host ArgoCD.

## Decision

The hub (ArgoCD and, later, Grafana) runs in prod. Dev becomes a spoke
in sub-project 4. Until then dev keeps its own ArgoCD, reachable as
`dev-argocd.mgryn.cc`; that name is transitional, and `argocd.mgryn.cc`
is prod.

**Bootstrap.** The existing `roles/argocd`, run by
`playbooks/argocd-prod.yaml` on the operator's workstation, installs
ArgoCD on prod. It uses a kubeconfig extracted with
`terraform output -raw kubeconfig` into a mode-600 temporary file; the
kubeconfig never reaches git. Afterwards the operator applies
`argocd/base/projects.yaml` and prod's app-of-apps by hand, as on dev.

**Vault.** A second Kubernetes auth mount, `kubernetes-prod`, carries
the policy `argocd-read-prod`, which reads `kv-prod` only. AVP selects
it with `AVP_K8S_MOUNT_PATH: auth/kubernetes-prod`. Talos has no SSH, so
the vault role reads the reviewer token and CA through the kubeconfig.
Runs choose clusters with `vault_k8s_cluster_names`, so a dev-only run
needs no prod kubeconfig.

**Name resolution.** Prod resolves `vault.mgryn.cc` with pod-level
`global.hostAliases` on the ArgoCD chart, which has no repoServer-only
key. No CoreDNS patch: Talos manages the CoreDNS ConfigMap.

**Stale Applications.** The pre-Talos `nfs.yaml` and `monitoring.yaml`
in `argocd/environments/prod/applications/` are deleted. Once the
operator applies `root-prod` they would sync from `main` and deploy
stale manifests before the next PR replaces them, so `root-prod` starts
with only `argocd-config`. The overlays under `argocd/apps/` stay until
they are rewritten.

`argocd/base/projects.yaml` gains the prometheus-community Helm
repository in `sourceRepos`: both ArgoCDs sync `argocd/base`, and an
Application whose repository is not allowed is refused.

Rejected:

- **ArgoCD in `shared`**: not a cluster.
- **A Terraform `helm_release` for the bootstrap**: the Vault and
  repository secrets would flow through Terraform state.
- **Two self-contained clusters, each with its own ArgoCD**: about 6G
  of duplicated workloads on a 31G host.

## Consequences

- Dev cannot deploy while prod is down.
- Prod's reviewer JWT Secret exists only after prod's `argocd-config`
  syncs, so Vault's prod auth is configured after the first sync.
- Later PRs extend this record with the monitoring decisions.

## Related

`docs/superpowers/specs/2026-10-03-prod-platform-hub-design.md`; records
[0004](0004-secrets-in-vault-via-avp.md),
[0021](0021-talos-prod-via-terraform-provider.md).
