# 0032. Grafana dashboards are jsonnet, rendered to committed JSON

**Status:** Accepted (2026-10-13)

## Context

Grafana runs on the prod hub with its state on the cluster's storage,
which lives on the single SSD. A dashboard built in the UI dies with the
disk, and a rebuild brings Grafana back with none of them. The community
dashboards available are mostly 2021-era JSON exports: they target old
metric names, carry hundreds of lines of generated layout, and cannot be
reviewed in a diff.

## Decision

**Dashboards are written in jsonnet and rendered to JSON that is
committed.** Argo delivers the committed JSON; nothing renders at sync
time.

- **Source:** `dashboards/src/<name>.jsonnet`, with shared helpers in
  `dashboards/lib/`. Two dashboards exist: Homelab overview (uid
  `homelab-overview`) and Proxmox (uid `proxmox`).
- **Render:** `scripts/check-dashboards.sh --write` writes
  `argocd/apps/grafana-dashboards/prod/<name>.json`. Without `--write`
  the script compares and fails on drift, so CI proves the committed JSON
  is exactly what the source renders.
- **Delivery:** the `grafana-dashboards` app's kustomize
  `configMapGenerator` turns each JSON into a ConfigMap in `monitoring`
  with the label `grafana_dashboard: "1"` and the annotation
  `grafana_folder: Homelab`. Grafana's sidecar loads them into the
  Homelab folder.
- **Community dashboards are reference only.** They are read for panel
  ideas and queries, never imported or vendored.
- **No full mixin format.** The monitoring-mixins layout (jsonnet
  producing dashboards, rules and alerts together) is more than two
  dashboards need; alert rules stay in `argocd/apps/alerts`.
- **Grafonnet `gen/grafonnet-v11.4.0`,** pinned by `jb` in
  `dashboards/jsonnetfile.lock.json` to a commit. The generated v11.4
  library matches the Grafana 11 schema the chart ships and is typed, so a
  misspelled field fails the render instead of producing a panel that
  silently ignores it. `dashboards/vendor/` is gitignored and fetched by
  `jb install`.
- **No swap panel on the Proxmox dashboard:** `pve-exporter` exposes no
  swap metric, and a panel on a metric that does not exist reads as zero.

## Consequences

- Toolchain pins: go-jsonnet `0.22.0` and jsonnet-bundler `0.6.0` are
  set in the `env:` block of `.github/workflows/ci.yaml` with SHA-256
  digests and `# renovate:` comments, like the other CI tools. Anyone
  editing a dashboard needs `jsonnet`, `jsonnetfmt`, `jb`, `kustomize`
  and `yq` on the operator's workstation.
- Every dashboard change is two files in the same commit: the source and
  the rendered JSON. CI's `dashboards` job fails when they differ. The
  job is gated by a paths filter
  ([ADR 0031](0031-path-gated-ci.md)) on `dashboards/**`,
  `argocd/apps/grafana-dashboards/**` and `scripts/check-dashboards.sh`.
- `jsonnetfmt` is a `language: system` pre-commit hook, skipped in CI's
  `pre-commit` job (`SKIP=...,jsonnetfmt`) and run by the `dashboards`
  job instead.
- A new dashboard must be listed in the app's `kustomization.yaml`; the
  check fails on a JSON that is not.
- The sidecar needs `folderAnnotation` and `foldersFromFilesStructure`
  enabled to honour `grafana_folder`. They are set in
  `argocd/apps/kube-prometheus-stack/prod/values.yaml`; without them
  every dashboard lands in the General folder.
- A UI edit to a provisioned dashboard is lost at the next sync. Edit the
  source.
- Deferred to a second pull request: a jobboard dashboard, platform
  dashboards, and ArgoCD metrics scraping.
