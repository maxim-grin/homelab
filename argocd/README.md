# ArgoCD

## Directory structure

```txt
argocd/
├── base/                          # the homelab AppProject, synced by argocd-config
│   ├── projects.yaml
│   ├── vault-auth-delegator.yaml  # vault-auth ServiceAccount + Secret for Vault's Kubernetes auth
│   └── kustomization.yaml
├── apps/                          # one directory per app (ADR 0026)
│   ├── <app>/config.yaml          # which envs it deploys to, namespace, sync options
│   ├── <app>/base/                # shared manifests, where an app has them
│   ├── <app>/dev/  <app>/prod/    # kustomize per env (Helm via helmCharts)
│   └── clusters/                  # the dev and prod cluster Secrets
├── environments/
│   └── prod/applications/         # root-prod's children, on the hub
│       ├── app-of-apps.yaml       # root application (root-prod)
│       ├── appset.yaml            # ApplicationSet: <cluster>-<dir> apps, prod and dev
│       ├── argocd-config.yaml     # syncs argocd/base
│       ├── clusters.yaml          # the prod cluster Secret app
│       └── clusters-dev.yaml      # the dev cluster Secret app
└── README.md
```

Apps today: `alerts`, `cert-manager`, `cert-manager-issuers`,
`grafana-dashboards`, `ingress-nginx`, `jobboard`, `kube-prometheus-stack`,
`monitoring-secrets`, `nfs-provisioner`, `pve-exporter`. Each `config.yaml`
says which of them reach dev and prod. The hub bootstrap order is in
[docs/rebuild.md](../docs/rebuild.md).

### Step 1: Apply ArgoCD Projects (Bootstrap Only)

```bash
kubectl apply -f argocd/base/projects.yaml
```

Genuinely one-time: this bootstraps the `homelab` AppProject before
anything else can sync. From then on, the `argocd-config` Application
(`argocd/environments/prod/applications/argocd-config.yaml`) owns
`argocd/base/` and syncs it on every push — a `sourceRepos` change no
longer needs a manual apply. Its `syncPolicy` sets `prune: false`
because it manages the AppProject that authorises every other
Application; a prune that removed it would orphan the whole cluster
at once. `prune: false` only guards against file deletion, though: a
commit that edits `sourceRepos` to drop the homelab repo URL is still
applied by `selfHeal` and locks every Application, `argocd-config`
included, out with "application repo is not permitted" — recovery is
`kubectl apply -f argocd/base/projects.yaml` by hand, since ArgoCD can
no longer read the repo to sync a revert. Deleting the `homelab`
AppProject outright is a similar dead end: `argocd-config` declares
`project: homelab`, so with the project gone it can't sync either, and
nothing is left to recreate the AppProject except that same manual
apply.

### Step 2: Deploy Root Application (App of Apps), on the prod hub

```bash
kubectl apply -f argocd/environments/prod/applications/app-of-apps.yaml
```
