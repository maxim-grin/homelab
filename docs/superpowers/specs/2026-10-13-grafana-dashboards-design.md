# Grafana dashboards as code

Status: draft for review. Builds on the prod monitoring hub
([spec](2026-10-03-prod-platform-hub-design.md)) and uniform apps
([spec](2026-10-05-uniform-apps-design.md), ADR 0026).

## Goal

Open Grafana and see how the homelab's own things are doing: the
Proxmox host, the apps, the platform. Today it holds only the
chart-bundled kubernetes-mixin and node-exporter dashboards, none of
which names an app or the Proxmox host.

## Decisions

- **Jsonnet is the source.** Dashboards are written in jsonnet with
  Grafonnet. Rendered JSON is committed next to the manifests; ArgoCD
  ships the JSON, so the cluster never needs the toolchain. Chosen over
  raw JSON (noisy diffs, no reuse) and the Grafana Operator (a second
  operator for one Grafana).
- **Dashboards are borrowed from, not imported.** Community dashboards
  for pve-exporter (grafana.com 24550, 10347) and ArgoCD (14584, 19974,
  19993, 24192) inform which panels exist. Their JSON is not committed:
  it is years old and its queries are not ours.
- **Not the full mixin format.** Alerts stay in the `alerts` app;
  dashboards get their own app. A chart upgrade, an alert change and a
  dashboard change stay separate diffs.
- **One home dashboard.** Everything else links from it.
- **Prod Grafana only.** It already queries the dev spoke through the
  hub; dev gets no dashboards app.
- **Two pull requests.** PR 1 lands the toolchain with the first
  dashboards, PR 2 the rest.

## Layout

```txt
dashboards/                      source of truth
  jsonnetfile.json, .lock.json   jb pins grafonnet to a commit
  lib/                           shared panel, query and colour helpers
  src/<name>.jsonnet             one file per dashboard
  vendor/                        gitignored, restored by jb from the lock
argocd/apps/grafana-dashboards/  new app, prod only
  config.yaml
  prod/kustomization.yaml        configMapGenerator over the rendered JSON
  prod/<name>.json               committed render output
scripts/check-dashboards.sh      render everything, diff against committed
```

## Delivery

- Each dashboard is a ConfigMap in `monitoring`, labelled
  `grafana_dashboard: "1"`, with a `grafana_folder` annotation
  ("Homelab"). The chart's existing sidecar loads it.
- `serverSideApply: true` in `config.yaml`: dashboard ConfigMaps are
  large and the client-side last-applied annotation has a 256 KiB limit.
- Order: after `kube-prometheus-stack` (Grafana and its sidecar). The
  ApplicationSet retry carries a sync that runs early.
- To verify in the plan: the sidecar's namespace scope in the prod
  values, and that dashboards render without a datasource UID guess
  (use the chart's default datasource name).

## Tooling and CI

- `jsonnet` (go-jsonnet) and `jb` versions are pinned in
  `scripts/check-dashboards.sh` and in CI, installed the way the other
  CI tools are.
- `check-dashboards.sh` runs `jb install`, `jsonnetfmt --test`, renders
  every `src/*.jsonnet`, and fails when the output differs from the
  committed JSON. A pre-commit hook runs the format check.
- Gated by path like the other jobs (ADR 0031).
- Test: the script against a fixture with a stale render and a good one,
  in `scripts/tests/`.

## PR 1: toolchain, overview, Proxmox

- Toolchain, app, check script, CI job, ADR, docs.
- **Homelab overview** (home): nodes up, pods not ready, firing alerts,
  certificates expiring soon, Proxmox thin-pool use, `jobs.mgryn.cc`
  request rate and 5xx. Links to every other dashboard.
- **Proxmox**: host CPU, memory, swap, storage and thin-pool, per-guest
  CPU, memory, disk and network, guest up/down, uptime. Metric names and
  labels come from the live `/pve` output, not from the community
  dashboards; the plan's first task records them.

## PR 2: apps and platform

- **jobboard**: pod and restart state, Postgres PVC use, crawl CronJob
  last success and duration, ingress rate, latency and errors for its
  host, container CPU and memory. Existing metrics only.
- **Platform**: ingress-nginx traffic and errors per host, certificate
  expiry table, NFS provisioner and PVC use, ArgoCD sync and health.
- **ArgoCD is not scraped today** (an Explore query for argocd series
  returns nothing). PR 2 adds PodMonitors for the application
  controller, server, repo-server and applicationset controller, in the
  new app or beside `alerts/prod/podmonitors.yaml`. ArgoCD itself is
  installed by Ansible Helm, so no playbook run is needed. A rule for
  absent ArgoCD metrics follows the existing `*MetricsAbsent` pattern.

## Not now

- LAN service exporters (Pi-hole, Traefik, Gatus): separate PR, needs
  new exporters on the LXCs.
- Vault and Postgres exporters.
- Grafana-side alerting. Alerts stay in Prometheus rules.

## Risks

- **"No data" from guessed metric names.** Mitigation: the Proxmox
  dashboard is written against pasted live output; each dashboard's
  verification step is opening it and checking every panel populates.
- **Toolchain drift.** Pinned versions plus the CI render diff.
- **Grafonnet API churn.** The lockfile pins a commit; upgrades are
  deliberate and show up as a render diff.
- **Grafana state not in git is lost on rebuild.** Intended; this spec
  is the fix.

## Docs

ADR (dashboards as jsonnet, rendered JSON committed), README table row,
`docs/operations.md` section on editing and rendering, and a
`docs/runbooks/` entry for the render command, linked from each PR's
operator checklist.
