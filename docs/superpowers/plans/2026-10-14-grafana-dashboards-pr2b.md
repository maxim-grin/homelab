# Grafana dashboards part 2b Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `env` dropdown, a jobboard dashboard, a Platform dashboard
(with ArgoCD panels), a home dashboard and a tag link to every dashboard.

**Architecture:** Same pipeline as PR 1: `dashboards/src/<n>.jsonnet`
imports `dashboards/lib/homelab.libsonnet`, renders to
`argocd/apps/grafana-dashboards/prod/<n>.json`, and one
`configMapGenerator` entry per dashboard delivers it. The lib grows an
`env` variable helper and a tag-based link; the Grafana chart values gain
a home-dashboard path.

**Tech Stack:** go-jsonnet, Grafonnet `gen/grafonnet-v11.4.0`, jb,
kustomize, `scripts/check-dashboards.sh`, kube-prometheus-stack 92.3.0.

**Spec:** `docs/superpowers/specs/2026-10-14-grafana-dashboards-pr2b-design.md`
(parent: `2026-10-13-grafana-dashboards-design.md`; PR 1 plan:
`2026-10-13-grafana-dashboards-pr1.md`).

## Global Constraints

- Branch `dashboards-apps-platform`, draft PR #159. Never push or merge `main`.
- Tools: `export PATH=/tmp/claude-1000/-home-ubuntu-homelab/b7a047ab-dc4d-44f1-a819-2063ce4a44ce/scratchpad/bin:$PATH` before `scripts/check-dashboards.sh` or committing (jsonnetfmt hook). Pre-commit locally: `SKIP=ansible-lint,terraform-fmt`.
- Commits: Conventional, types feat/fix/refactor/docs/chore/ops only, subject <=50 chars, imperative, lowercase, no trailing period, body wrapped at 72. No `Co-Authored-By`, no generated-with line. Never `--no-verify`.
- Dashboard JSON is never hand-edited: `scripts/check-dashboards.sh --write` renders it; commit source and JSON together.
- uid = file name without extension (`jobboard`, `platform`). Every dashboard keeps the `homelab` tag (the lib adds it).
- Queries use only metric names confirmed in the spec's "Confirmed series" or by Task 0's paste. A name not in either is not used; report NEEDS_CONTEXT instead.
- `env` filters `cluster="$env"`. Ingress panels use `cluster="prod"` (dev ingress is not scraped). ArgoCD panels have no cluster filter (hub-wide).
- Docs are not caveman. Wording: "operator's workstation".
- Exact values: Grafana folder `Homelab`; chart dashboard uids `efa86fd1d0c121a26444b636a3f509a8` and `7d57716318ee0dddbac5a7f451fb7753` (existing overview links, keep).

## Review Focus

- `env=dev` on the overview: tiles read dev data or show 0/no data, never prod's; firing-alerts tile and ingress tiles stay prod and say so in their titles.
- A dashboard with the `env` variable but a panel still hard-coded to `cluster="prod"` or `!="dev"` by accident (grep the rendered JSON for `cluster!=`).
- Counts use `or vector(0)` so an empty result is 0, not "No data", except where "No data" is the honest answer (CronJob last-success before its first run).
- Two `links` sources collide: `withLinks` replaces, so the lib's tag link must be added with `withLinksMixin`, or the per-dashboard chart links vanish.
- ArgoCD tiles count `argocd_app_info` series; a second controller replica would double them (use `max by (name)` before counting).
- New dashboard JSON not listed in the kustomization: the check script fails; confirm it does.

---

### Task 0: Operator metric paste (supervisor, before Task 2)

Not delegated: the supervisor asks the operator and records the answer in the ledger.

- [ ] **Step 1: Ask the operator to run in Explore (prod Prometheus) and paste:**

```promql
count by (__name__) ({__name__=~"kube_pod_container_status_restarts_total|container_cpu_usage_seconds_total|container_memory_working_set_bytes|nginx_ingress_controller_request_duration_seconds_bucket|kube_deployment_status_replicas_available|kube_persistentvolumeclaim_status_phase", cluster="prod"})
```
```promql
topk(2, kubelet_volume_stats_used_bytes{cluster="prod"})
```
```promql
topk(2, certmanager_certificate_expiration_timestamp_seconds{cluster="prod"})
```
```promql
kube_deployment_status_replicas_available{cluster="prod", namespace="nfs-system"}
```

- [x] **Step 2 (partial, 2026-10-14):** confirmed live: all six names exist in prod (CPU 110 series, memory 110, request-duration buckets 528, deployment replicas 16, PVC phase 9, restarts 40). `kubelet_volume_stats_*` labels: `cluster`, `namespace`, `persistentvolumeclaim` (jobboard's is `data-postgres-0`; dev has it too, prod's grafana PVC is `monitoring-grafana`). Certificate and nfs-system deployment labels not pasted: use cert-manager's documented `name`, `namespace` and kube-state-metrics' `deployment`, marked unverified in the PR.
- [ ] **Step 3:** Record in the ledger the exact label names (PVC label, certificate name/namespace labels, deployment name). A missing metric means that panel is dropped or swapped, ruled in the ledger.

### Task 1: Lib `env` variable, tag link, retrofit

**Files:**
- Modify: `dashboards/lib/homelab.libsonnet`, `dashboards/lib/README.md`
- Modify: `dashboards/src/overview.jsonnet`, `dashboards/src/proxmox.jsonnet`
- Regenerate: `argocd/apps/grafana-dashboards/prod/overview.json`, `proxmox.json`

**Interfaces:**
- Produces: `h.envVar()` returns a Grafonnet query variable named `env`: `label_values(up, cluster)`, datasource `h.ds`, single-select, default `prod`, refresh on dashboard load, sorted. `h.cluster` is the string `cluster="$env"`. `h.dashboard(...)` now includes a dashboard-type link (tag `homelab`, shown as dropdown, title `Homelab dashboards`) added with `withLinksMixin`, so every dashboard has it.
- Consumes: existing `h.dashboard`, `h.withPanels`.

- [ ] **Step 1:** Add `envVar`, `cluster` and the tag link to the lib. The per-dashboard `links` arrays in overview and proxmox must switch from `withLinks` to `withLinksMixin`, and drop the `Proxmox` and `Homelab overview` link entries the tag link now covers; keep the two chart-dashboard links.
- [ ] **Step 2:** Overview: add `h.envVar()` via `g.dashboard.withVariables`; replace each `cluster!="dev"` with `h.cluster` interpolated; retitle the firing-alerts stat and table `Firing alerts (prod)`. Proxmox gets the tag link only, no `env`.
- [ ] **Step 3:** Update `dashboards/lib/README.md` table with `h.envVar()`, `h.cluster`, the tag link, and the stat default steps (PR 1 leftover).
- [ ] **Step 4: Render and check**

Run: `scripts/check-dashboards.sh --write && scripts/check-dashboards.sh && grep -c 'cluster!=' argocd/apps/grafana-dashboards/prod/overview.json`
Expected: both script runs exit 0; grep prints `0`. `jq '.templating.list[].name' argocd/apps/grafana-dashboards/prod/overview.json` prints `"env"`.
- [ ] **Step 5: Commit** `feat: env variable and tag link in lib`

### Task 2: jobboard dashboard

**Files:**
- Create: `dashboards/src/jobboard.jsonnet`, `argocd/apps/grafana-dashboards/prod/jobboard.json` (rendered)
- Modify: `argocd/apps/grafana-dashboards/prod/kustomization.yaml` (new `dashboard-jobboard` generator, identical options to the others)

**Interfaces:**
- Consumes: `h.envVar()`, `h.cluster`, `h.dashboard('Jobboard', 'jobboard', ['app'])`, `h.stat`, `h.timeseries`, `h.table`.
- Produces: a second variable `host` (query `label_values(nginx_ingress_controller_requests{cluster="prod", host!=""}, host)`, single-select, sorted), used only by the ingress panels.

Panels (namespace `jobboard`, all with `h.cluster` unless stated; names confirmed by spec or Task 0):
- Stat pods not ready: `kube_pod_status_ready{condition="false"}`.
- Stat container restarts, 1h: `increase(kube_pod_container_status_restarts_total[1h])`, summed.
- Timeseries pod restarts by pod.
- Timeseries PVC use fraction: `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes` by the PVC label from Task 0; unit `percentunit`, amber 0.7, red 0.8 on the stat variant.
- CronJob `jobboard-crawl`: stats for `kube_cronjob_spec_suspend`, `kube_cronjob_status_active`, and next run in seconds (`kube_cronjob_next_schedule_time - time()`, unit `s`); stat last success age (`time() - kube_cronjob_status_last_successful_time`) and timeseries duration (`kube_job_status_completion_time - kube_job_status_start_time`, `job_name=~"jobboard-crawl-.*"`) written from documented names and left without `or vector(0)`; title both `(after first run)`. Dev has no CronJob manifest: these read "No data" for `env=dev`; say so in the dashboard's description.
- Ingress, titles end `(prod)`, `cluster="prod"`, `host="$host"`: requests per second, 5xx ratio (guard divide with `clamp_min`), p95 latency from `nginx_ingress_controller_request_duration_seconds_bucket` if Task 0 confirms it, else dropped.
- Timeseries container CPU (`rate(container_cpu_usage_seconds_total{container!=""}[5m])`) and memory (`container_memory_working_set_bytes{container!=""}`) by container, if Task 0 confirms names.

- [ ] **Step 1:** Write the source and the kustomization entry. Before rendering, run `scripts/check-dashboards.sh` and confirm it FAILS (JSON missing / not listed).
- [ ] **Step 2: Render and check**

Run: `scripts/check-dashboards.sh --write && scripts/check-dashboards.sh && kustomize build argocd/apps/grafana-dashboards/prod | grep -c 'grafana_dashboard: "1"'`
Expected: exit 0; the count is `3`.
- [ ] **Step 3: Commit** `feat: jobboard grafana dashboard`

### Task 3: Platform dashboard

**Files:**
- Create: `dashboards/src/platform.jsonnet`, `argocd/apps/grafana-dashboards/prod/platform.json` (rendered)
- Modify: `argocd/apps/grafana-dashboards/prod/kustomization.yaml` (`dashboard-platform`)

**Interfaces:**
- Consumes: Task 1 lib. Variable `env` only.

Rows, in this order:
- Ingress (prod): timeseries requests per second by `host`; timeseries 5xx ratio by `host`; `host!=""`, `cluster="prod"`; p95 per host if Task 0 confirms the histogram.
- Certificates (`h.cluster`): table of `certmanager_certificate_expiration_timestamp_seconds - time()` with days remaining and the name/namespace labels from Task 0, soonest first, amber under 21 days, red under 14 (overview threshold); stat of certificates not ready from `certmanager_certificate_ready_status{condition=~"False|Unknown"} == 1`, counted with `or vector(0)`.
- NFS (`h.cluster`): stat nfs provisioner available replicas (`kube_deployment_status_replicas_available{namespace="nfs-system"}`, red at 0); timeseries PVC use fraction for all PVCs (`kubelet_volume_stats_*`).
- ArgoCD (hub-wide, no env filter; row title says so): stats for apps total, not Synced (`sync_status!="Synced"`), not Healthy (`health_status!="Healthy"`), without autosync (`autosync_enabled!="true"`), all `or vector(0)` and over `max by (name) (argocd_app_info{...})` so a second replica does not double count; table of apps not Synced or not Healthy with columns name, project, dest_namespace, dest_server, sync_status, health_status.

- [ ] **Step 1:** Source and kustomization entry; run the check and confirm it fails first.
- [ ] **Step 2: Render and check**

Run: `scripts/check-dashboards.sh --write && scripts/check-dashboards.sh && kustomize build argocd/apps/grafana-dashboards/prod | grep -c 'grafana_dashboard: "1"'`
Expected: exit 0; the count is `4`.
- [ ] **Step 3: Commit** `feat: platform grafana dashboard`

### Task 4: Home dashboard, ADR, docs

**Files:**
- Modify: `argocd/apps/kube-prometheus-stack/prod/values.yaml` (`grafana.grafana.ini` gains a `dashboards:` section, `default_home_dashboard_path: /tmp/dashboards/Homelab/overview.json`, with a comment saying the sidecar writes dashboards to `/tmp/dashboards/<folder>/<key>` because `foldersFromFilesStructure` is on)
- Modify: `docs/decisions/0032-dashboards-as-jsonnet.md` (new section: `env` variable, hub-wide ArgoCD choice and why, ingress prod-only until dev is scraped, home dashboard, tag link; update "Two dashboards exist" to four)
- Modify: `README.md` Dashboards row (four dashboards), `docs/runbooks/checks.md` section "Edit a Grafana dashboard" (note `env` and `host` dropdowns, and the post-merge home-dashboard check), `docs/operations.md` only if it lists dashboards (grep first)

- [ ] **Step 1:** Make the edits above. Do not restate commands in the PR body; link the runbook entry.
- [ ] **Step 2: Verify**

Run: `kustomize build --enable-helm argocd/apps/kube-prometheus-stack/prod | grep -n default_home_dashboard_path` and `pre-commit run --all-files` with the Global Constraints env.
Expected: one grep line naming the path; pre-commit passes (`check-manifests.sh` kube-prometheus-stack failure is the known helm-3 local limitation, CI is the check).
- [ ] **Step 3: Commit** `docs: adr and runbook for dashboards part 2b`; the values change is its own commit `feat: grafana home dashboard is overview`.
- [ ] **Step 4:** Supervisor: write the PR body with the operator checklist (below), `gh pr ready 159` only after CI is green and the final whole-branch review is clean.

## Operator checklist (goes in the PR body)

1. After merge: Grafana restarts once (home-dashboard setting). Confirm `kubectl -n monitoring exec deploy/monitoring-grafana -c grafana -- ls /tmp/dashboards/Homelab` lists `overview.json`; if the path differs, fix `default_home_dashboard_path` in a follow-up.
2. Four ConfigMaps: `kubectl -n monitoring get cm -l grafana_dashboard=1`.
3. Each dashboard in folder Homelab, every panel shows data for `env=prod`; `env=dev` panels show data except ingress, CronJob and ArgoCD (expected).
4. After the first crawl (04:00 UTC): `count by (__name__) ({__name__=~"kube_job_.*|kube_cronjob_status_last_.*", cluster="prod"})` returns series, and the two `(after first run)` panels fill.
