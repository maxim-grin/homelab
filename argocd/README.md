## 📁 Directory Structure

```txt
argocd/
├── base/                        # ArgoCD base configuration
│   ├── projects.yaml           # ArgoCD Projects (homelab)
│   └── kustomization.yaml
├── apps/                        # Application manifests
│   └── monitoring/             # Grafana + Prometheus stack
│       ├── namespace.yaml
│       ├── prometheus/         # Prometheus configs
│       ├── grafana/            # Grafana configs
│       └── kustomization.yaml
├── environments/                # Environment-specific ArgoCD apps
│   ├── dev/
│   │   └── applications/
│   │       ├── app-of-apps.yaml      # Root application
│   │       └── monitoring.yaml       # Monitoring app definition
│   └── prod/
│       └── applications/
│           ├── app-of-apps.yaml      # Root application
│           └── monitoring.yaml       # Monitoring app definition
└── readme.md
```

### Step 1: Apply ArgoCD Projects (Bootstrap Only)

```bash
kubectl apply -f argocd/base/projects.yaml
```

Genuinely one-time: this bootstraps the `homelab` AppProject before
anything else can sync. From then on, the `argocd-config` Application
(`argocd/environments/dev/applications/argocd-config.yaml`) owns
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

### Step 2: Deploy Root Application (App of Apps)

```bash
kubectl apply -f argocd/environments/dev/applications/app-of-apps.yaml
```
