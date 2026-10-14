# Grafana dashboards, part 2b: apps and platform

Continues [the dashboards design](2026-10-13-grafana-dashboards-design.md).
PR 1 (#155) delivered the toolchain, the overview and Proxmox
dashboards; #156 labelled prod's own series `cluster="prod"` and #158
scrapes ArgoCD. This PR adds the dashboards that needed both.

## Goal

Answer "is jobboard healthy, and is the platform under it healthy?" from
one Grafana folder, for prod and for dev, without writing PromQL.

## Decisions

- **`env` dropdown in the shared lib.** One helper adds a query variable
  `env` (`label_values(up, cluster)`, default `prod`, single value). Panels
  that are per-environment filter `cluster="$env"`. The overview drops its
  hard-coded `cluster!="dev"` for it; its firing-alerts tile stays
  prod-only, because only prod evaluates rules. Proxmox has no `env`
  (one host).
- **ArgoCD panels are hub-wide, with no `env` filter.** Every
  `argocd_app_info` series carries `cluster="prod"`: the hub that scrapes
  it, not the app's target. The target is `dest_server`
  (`https://kubernetes.default.svc` prod, `https://10.0.0.101:6443` dev),
  and the app names do not all carry an env prefix (`argocd-config`,
  `clusters`, `root-prod`). Panels group by `name`, `project`,
  `dest_namespace`.
- **Jobboard host is a dropdown, not a constant.** A `host` variable
  from `label_values(nginx_ingress_controller_requests{cluster="prod",
  host!=""}, host)` keeps hostnames out of the dashboard code. Prod only
  while dev's ingress is unscraped (see "Not in this PR"); the dropdown
  can follow `env` once dev is scraped.
- **Home dashboard and links.** `grafana.ini` `default_home_dashboard_path`
  points at the overview file the sidecar writes; every dashboard gets a
  tag-based dashboard link (`homelab` tag) so each reaches the others.
- **Queries are written against real output.** The metrics below are
  confirmed live; every other metric a panel needs is confirmed by the
  operator's Explore paste before its panel is written.

## Confirmed series

- `argocd_app_info{name, project, dest_namespace, dest_server,
  sync_status, health_status, autosync_enabled, repo}`, 21 series, all
  `Synced`/`Healthy` on 2026-10-14. `job="monitoring/argocd"`.
- `nginx_ingress_controller_requests{host, ingress, namespace, status,
  method, path, service, cluster}`; prod scrapes it via
  `job="monitoring/ingress-nginx-controller"`.
- `up`, kube-state-metrics and cAdvisor series carry `cluster`.

## Dashboards

- **jobboard** (`env`, `host`): pod phase and restarts, Postgres PVC use,
  crawl CronJob last success and duration, ingress rate, 5xx ratio and
  latency for `$host`, container CPU and memory of the `jobboard`
  namespace. Existing metrics only.
- **Platform** (`env`): ingress rate and 5xx per host, certificate expiry
  table (cert-manager), NFS provisioner and PVC use, then the ArgoCD row
  (hub-wide): apps by `sync_status` and `health_status`, a table of apps
  that are not Synced and Healthy, apps without autosync.

## Not in this PR

- Dev ingress metrics. `count by (cluster)
  (nginx_ingress_controller_requests)` on 2026-10-14 returned prod only
  (44 series): dev's ingress-nginx is not scraped. The ingress rows of
  jobboard and Platform are therefore prod-only (`cluster="prod"`, not
  `$env`), titled as such; the `host` dropdown follows prod. Everything
  else on the jobboard dashboard honours `env`. Scraping dev's ingress is
  a separate PR.
- Grafana-side alerting, LAN exporters, Vault and Postgres exporters
  (unchanged from the parent spec).
- PR 1 leftovers: `perGuestRate` dedupe, uid-from-filename enforcement.
  Taken only if a task touches them.

## Docs and checks

ADR 0032 gains a section for `env`, the hub-wide ArgoCD choice and the
home dashboard. README dashboards row and the lib README list the new
helper. The "Edit a Grafana dashboard" runbook gains the `env`/`host`
note. `scripts/check-dashboards.sh` and CI already cover new files under
`dashboards/src`.

## Verification

CI renders and checks the JSON. Panels showing data is confirmed live by
the operator, for `env=prod` and `env=dev`, and listed in the PR's
operator checklist. The Grafana restart for the home-dashboard setting is
the only rollout step.
