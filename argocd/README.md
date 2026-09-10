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
at once.

### Step 2: Deploy Root Application (App of Apps)

```bash
kubectl apply -f argocd/environments/dev/applications/app-of-apps.yaml
```
