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
  `dashboards/lib/`. Four dashboards exist: Homelab overview (uid
  `homelab-overview`), Proxmox (uid `proxmox`), jobboard (uid
  `jobboard`) and platform (uid `platform`).
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
  library emits `schemaVersion` 39 dashboards, which the chart's
  Grafana 13 (`kube-prometheus-stack` 92.3.0, grafana subchart 13.5.0,
  appVersion 13.2.3) migrates forward on load. The library is typed, so a
  misspelled field fails the render instead of producing a panel that
  silently ignores it. No Grafonnet 13 library was used; moving to
  `gen/grafonnet-v13.0.0` is a deliberate later upgrade.
  `dashboards/vendor/` is gitignored and fetched by
  `jb install`.
- **An `env` dropdown selects the spoke.** The overview, jobboard and
  platform dashboards carry a single-select `env` variable
  (`label_values(up, cluster)`, default `prod`), and every selector in
  them matches `cluster="$env"` (`h.envVar()` and `h.cluster` in
  `dashboards/lib/`). The jobboard dashboard also has a `host` dropdown,
  which applies to prod only.
- **ArgoCD panels are hub-wide, not per `env`.** The hub's Prometheus
  scrapes the one ArgoCD, so every `argocd_app_info` series carries
  `cluster="prod"`, the hub, whatever the application deploys to. The
  spoke an application targets is the `dest_server` label. Filtering
  those panels by `env` would show the hub's series under `prod` and
  nothing under `dev`, so they ignore the dropdown.
- **Ingress panels are prod-only for now.** Dev's ingress-nginx is not
  scraped (`nginx_ingress_controller_requests` has series for
  `cluster="prod"` only), so with `env=dev` those panels are empty. They
  start working when dev's ingress-nginx is scraped, with no dashboard
  change.
- **Grafana's home dashboard is the overview.** `grafana.ini` sets
  `default_home_dashboard_path` to
  `/tmp/dashboards/Homelab/overview.json`, where the sidecar writes the
  file (`/tmp/dashboards/<folder>/<key>`, because
  `foldersFromFilesStructure` is on). The setting needs a Grafana restart
  the first time, and a wrong path falls back to Grafana's default home
  page without an error.
- **Every dashboard links to the others by tag.** Each is tagged
  `homelab`, and `h.dashboard` adds a dropdown link, "Homelab dashboards",
  that lists every dashboard with that tag. A new dashboard needs the tag
  and nothing else.
- **Two jobboard panels wait for the crawl CronJob.** They read
  `kube_job_*` and `kube_cronjob_status_last_*` series, which exist only
  after the first run (04:00 UTC), and their titles end "(after first
  run)".
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
  `pre-commit` job (`SKIP: ansible-lint,terraform-fmt,jsonnetfmt`) and run by the `dashboards`
  job instead.
- A new dashboard must be listed in the app's `kustomization.yaml`; the
  check fails on a JSON that is not.
- The sidecar needs `folderAnnotation` and `foldersFromFilesStructure`
  enabled to honour `grafana_folder`. They are set in
  `argocd/apps/kube-prometheus-stack/prod/values.yaml`; without them
  every dashboard lands in the General folder.
- A UI edit to a provisioned dashboard is lost at the next sync. Edit the
  source.
- The `deployment` label on the platform dashboard's nfs-provisioner
  panels is unverified against the live series; correct it if a panel
  reads empty.
- The overview links to the chart's kubernetes-mixin and node-exporter
  dashboards by uid, pinned to chart 92.3.0; recheck them on a chart
  bump.
