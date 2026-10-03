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

**Platform apps.** Prod's `root-prod` delivers `nfs`, `cert-manager`,
`cert-manager-issuers`, `ingress-nginx`, `monitoring-secrets` and
`monitoring`. `nfs-prod` is the default StorageClass and keeps
`reclaimPolicy: Retain` with `archiveOnDelete: "true"`: a deleted PVC
leaves its directory on `nfs-01` and the PV `Released`, so a mistaken
delete loses nothing, and cleaning up is manual. `ingress-nginx` is a
DaemonSet on host ports 80/443 on the two workers, as on dev; Cloudflare
carries grey-cloud records for `argocd.mgryn.cc` and `grafana.mgryn.cc`
to both. Dev's Grafana is renamed `dev-grafana.mgryn.cc`, freeing the
name for the hub.

**`kube-prometheus-stack` replaces hand-rolled monitoring.** The chart
brings the Prometheus Operator and its CRDs: `ServiceMonitor` and
`PrometheusRule` objects are discovered across namespaces, so later PRs
add scrapes and alerts next to the thing they watch, and Grafana's
sidecar loads dashboards and datasources from labelled ConfigMaps. The
pre-Talos hand-written manifests are not reused. Prometheus runs one
replica on a 20Gi `nfs-prod` volume with `retentionSize` 15GB, under the
share, and the remote-write receiver on for the dev spoke later.
Prometheus's TSDB on NFS is not an upstream-supported store; the
design accepts it for a single replica with retention capped below the
volume. Grafana gets 5Gi on `nfs-prod` and a `letsencrypt-prod`
certificate.

**Alertmanager's configuration is a Secret rendered by AVP.** The
`monitoring-secrets` Application owns an `alertmanager-config` Secret,
which the chart reads through `configSecret`. The Telegram chat id is an
integer with no `_file` variant, so it cannot be read from a mounted
file; AVP substitutes the placeholder inside the whole configuration
before Alertmanager parses it, leaving a bare integer. The same Application creates the
`monitoring` Namespace and the `grafana-admin` Secret. Grafana reads the
admin password only when it first creates its database, so rotating the
Vault value afterwards changes nothing.

**Pod Security.** Talos's default admission policy is `baseline`, which
rejects `hostPort` and host namespaces. The `ingress-nginx` namespace
(host ports) and the `monitoring` namespace (the node exporter's host
network and `hostPath` mounts) are labelled `pod-security.kubernetes.io/enforce:
privileged`; no other namespace is. A refused pod shows as a
`FailedCreate` event on its DaemonSet.

**Scrapes Talos hides.** The controller-manager, scheduler, etcd and
kube-proxy scrapes are disabled: Talos binds their metrics to
localhost, so the targets would be permanently down and alert for no
reason.

**Sync waves order, they do not gate.** This ArgoCD has no Application
health check, so a wave does not wait for the previous Application to be
healthy; it only orders creation (`nfs` 0, `cert-manager` 1, issuers 2,
`ingress-nginx` 3, `monitoring-secrets` 4, `monitoring` 5). Retries on
`cert-manager-issuers` (the CRD race) and `monitoring` (the namespace
race) cover the gaps. They are finite: after a sealed-Vault outage the
Application stays `Sync failed` until someone unseals Vault and starts
a sync by hand, with a kubectl patch of the Application's `operation`
(a hard refresh re-compares but does not retry).

**The Proxmox thin pool reaches Prometheus through `pve-exporter`.**
The Proxmox host is the one machine whose `data%` on `local-lvm` can
fill the SSD under every VM, and nothing in the cluster sees it. The
`pve-exporter` Application (wave 6) runs the exporter in `monitoring`
and a `ServiceMonitor` scrapes its `/pve` path with the host as the
`target` parameter. Its credentials are a read-only `PVEAuditor` token
for `pve-exporter@pve`, created by the `pve-exporter` step of
`scripts/pve-bootstrap.sh` and shown once. The token fields and the
scrape target are `<path:kv-prod/data/monitoring/pve-exporter#...>`
placeholders: the host's address is recorded only in the encrypted
`secret.yaml`, so it comes from Vault, not from a committed manifest.

**PodMonitors for what nothing else scrapes.** `kube-prometheus-stack`
has no annotation-based scrape jobs, so the `prometheus.io/*`
annotations on ingress-nginx and cert-manager are ignored. The `alerts`
Application (wave 6) carries a `PodMonitor` for each: ingress-nginx's
metrics port 10254, which needs `controller.metrics.enabled`, and
cert-manager's `http-metrics` port 9402.

**Our rules cover only what the chart's defaults do not.** The chart
already alerts on a node not ready and a crash-looping pod; a second
copy would send each of those twice. The `alerts` Application adds
certificate expiry within 14 days and certificates not ready, an
unavailable NFS provisioner, Prometheus storage, an availability SLO on
each Ingress, and absence of the two scrape targets.

**Prometheus storage is measured from its own TSDB.** The rule sums the
head chunks, the WAL and the blocks and divides by
`prometheus_tsdb_retention_limit_bytes`, alerting above 80%. It does not
use `kubelet_volume_stats_*`: on an `nfs-subdir` PV the kubelet reports
the filesystem of the whole `nfs-prod` share, not the 20Gi claim, so the
ratio would be wrong. Size retention counts all three components, which
is why the sum is not blocks alone.

**Absence alerts guard the scrape targets.** A target that vanishes (a
chart upgrade renames a label, a PodMonitor stops matching) leaves no
`up` series, so the chart's `TargetDown` stays quiet and the
certificate and SLO rules look healthy. `IngressNginxMetricsAbsent` and
`CertManagerMetricsAbsent` fire when no target of the PodMonitor has
been up for 15 minutes.

**The SLO has a request-rate floor.** Ingress availability is 99% over
30 days. A page fires at 14.4 times the budget over 5m and 1h, a ticket
at 6 times over 30m and 6h. Each also needs a minimum of requests in
its long window (30 in 1h, 60 in 6h): on a quiet homelab Ingress a few
502s are a large ratio and not worth a page.

**The thin-pool rule is held.** The expected series are
`pve_disk_size_bytes` and `pve_disk_usage_bytes` with an `id` like
`storage/<node>/local-lvm`, but that is unconfirmed, and a rule written
against a guessed name stays silent without ever failing. The operator
observes the series on the live Prometheus first, in the alerting
rollout (`docs/rebuild.md` step 19); a follow-up PR then adds the rule,
with its `promtool` test. Until then only a comment in `rules.yaml`
names it.

**Alertmanager's route.** Alerts group by `alertname` and `namespace`.
The Telegram message's header comes from the highest severity firing in
the group: `PAGE` for `critical`, `TICKET` for `warning`, `RESOLVED`
once the group resolves. A message lists at most six alerts, because
Telegram rejects text cut mid-tag at 4096 characters. `Watchdog` and
`InfoInhibitor` go to a `null` receiver; only `critical` alerts repeat
sooner than the 12h default.

Rejected:

- **ArgoCD in `shared`**: not a cluster.
- **A Terraform `helm_release` for the bootstrap**: the Vault and
  repository secrets would flow through Terraform state.
- **Two self-contained clusters, each with its own ArgoCD**: about 6G
  of duplicated workloads on a 31G host.

## Consequences

- Once sub-project 4 lands, dev cannot deploy while prod is down; until
  then dev has its own ArgoCD.
- Prod's reviewer JWT Secret exists only after prod's `argocd-config`
  syncs, so Vault's prod auth is configured after the first sync.
- A silent Telegram does not prove a healthy cluster: `Watchdog` is
  routed to nowhere, so a dead Alertmanager or a bad Vault render shows
  only as the absence of messages. The operator's proof is a test alert
  (`docs/rebuild.md` step 19).
- The thin pool has no alert until the held rule lands; watch `data%`
  by hand in the meantime.
- Prod's Prometheus is a single replica on NFS: an NFS outage or a
  corrupt TSDB loses metrics, not the cluster; the cost is a lower
  retention ceiling and no high availability.
- A deleted `nfs-prod` PVC leaves a `Released` PV and a directory behind
  until the operator removes them.
- After a sealed Vault outage at bootstrap, `monitoring-secrets` and
  `cert-manager-issuers` show a `ComparisonError` and sync on their own
  once Vault is unsealed; `monitoring`, which needs the namespace
  `monitoring-secrets` creates, can be left `Sync failed` until a manual
  sync.

## Related

`docs/superpowers/specs/2026-10-03-prod-platform-hub-design.md`; records
[0004](0004-secrets-in-vault-via-avp.md),
[0021](0021-talos-prod-via-terraform-provider.md).
