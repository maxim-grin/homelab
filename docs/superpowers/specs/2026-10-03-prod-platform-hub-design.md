# Prod Platform Hub — Design

Roadmap sub-project 3 ([2026-09-26](2026-09-26-homelab-roadmap-design.md)).
The Talos prod cluster ([2026-10-01](2026-10-01-talos-prod-design.md)) is
applied and empty. This turns it into the hub: one ArgoCD and one Grafana
that sub-project 4 later points at dev.

## Problem

Prod has three Ready nodes and nothing on them. The roadmap's end state is
one ArgoCD UI showing both clusters' Applications and one Grafana showing
both clusters' metrics, both running in prod. Today:

- prod has no ArgoCD, no ingress, no certificates, no default StorageClass
- the `nfs-prod` export has no client list, so it has no export line
- `argocd/apps/monitoring/prod` is a leftover from the repo's original
  author: hand-rolled Prometheus, Grafana, kube-state-metrics and
  node-exporter manifests that predate Talos
- dev's ArgoCD answers on `argocd.mgryn.cc`, the name the hub needs
- nothing alerts on either cluster, or on the thin pool

## Decisions

| Question | Decision |
| --- | --- |
| Where the hub runs | Prod, per the roadmap. `shared` is not a cluster |
| ArgoCD bootstrap | The existing `roles/argocd`, run by a new playbook against a kubeconfig the operator extracts from Terraform at run time |
| Hub names | `argocd.mgryn.cc` and `grafana.mgryn.cc` |
| Dev's ArgoCD name | `dev-argocd.mgryn.cc`, transitional: gone when sub-4 retires it |
| DNS | Two grey-cloud Cloudflare A records per name, one per prod worker |
| Certificates | cert-manager, ACME DNS-01, token from `kv-prod/cert-manager/cloudflare` (ADR 0008) |
| Ingress | ingress-nginx DaemonSet on host ports 80/443, as on dev (ADR 0002) |
| Monitoring | `kube-prometheus-stack`, replacing the hand-rolled prod overlay; dev keeps its manifests until sub-4 |
| Prometheus storage | `nfs-prod`, 20Gi PVC, `retention.size` about 15GB |
| Pool `data%` source | `prometheus-pve-exporter` in prod, with a read-only PVE token |
| Alert routing | Alertmanager to the Telegram bot Gatus already uses |
| Prod worker RAM | 2G to 4G, both workers in one apply, while the cluster is empty |

## Design

### Control path and GitOps path

The operator writes `terraform output -raw kubeconfig` from
`environments/prod` to a temporary file and runs a new `argocd-prod.yaml`
playbook on localhost with that path as `argocd_context_kubeconfig`. The
role creates `cmp-plugin`, the AVP Secret (pointing at `kv-prod`) and
`vault-ca`, then the Helm release, as it does on dev. The NodePort stays
enabled as the break-glass way in. The kubeconfig never reaches git or disk
beyond the temporary file.

The play ends by applying `root-prod`, which watches
`argocd/environments/prod/applications/`. Everything after that reaches prod
by merge to `main`. `argocd-config` for the prod project follows the dev
pattern, and each new Helm repository joins `sourceRepos` before the
Application that uses it.

Prod's pods must resolve `vault.mgryn.cc`, which `playbooks/coredns_hosts.yaml`
arranges on dev through a CoreDNS `hosts` block, or AVP cannot reach Vault.
Talos has no `/etc/kubernetes/admin.conf` and no kubeadm upgrade to rewrite
the ConfigMap, so the mechanism differs. Which one (a Talos machine-config
patch, or the same CoreDNS block applied after bootstrap) is an open
question for the plan to settle by checking a running node; the spec fixes
only the requirement.

### Prod applications

Sync waves, in order:

1. `nfs-prod` StorageClass and provisioner, default class
2. cert-manager, then its issuers (production and staging)
3. ingress-nginx, a host-port DaemonSet on both workers
4. `kube-prometheus-stack`, then `prometheus-pve-exporter`

The existing prod `nfs_provisioner` overlay is checked against current
names and paths before reuse. `argocd/apps/monitoring/prod` is deleted.

### NFS and secrets

`nfs_server_prod_clients` is set to the exact worker addresses `.111` and
`.112`, never a subnet (ADR 0010), and the `nfs_server` play re-runs.
Prod's path is `/srv/nfs/prod`, the 50G `scsi2` disk.

AVP reads `kv-prod` only, through the policy that exists. Seeds come from
`secret.yaml`'s `vault_kv` block: the Cloudflare token for cert-manager, the
Grafana admin password, the Telegram bot token and chat id, and the
pve-exporter token. A committed manifest carries only
`<path:kv-prod/data/...#FIELD>` placeholders.

### Monitoring and alerting

`kube-prometheus-stack` gives the operator, `ServiceMonitor` and
`PrometheusRule` CRDs, and the Grafana sidecar, which is the point of
replacing the hand-rolled stack. Prometheus gets a 20Gi PVC on `nfs-prod`
with `retention.size` about 15GB so the TSDB cannot fill the share. Grafana
gets 5Gi. The remote-write receiver is enabled now, so sub-4 only adds the
sender.

`prometheus-pve-exporter` scrapes the Proxmox API with a read-only token,
which `scripts/pve-bootstrap.sh` creates, as it does for Glance. It exposes
the thin pool's `data%`.

Rules are committed as `PrometheusRule`s: node and pod health, certificate
expiry, the NFS provisioner down, Prometheus disk use, and thin-pool
`data%` at 80% (the roadmap's disk-budget rule). SLOs are a few burn-rate
rules over ingress request ratios. The rules are written to cover dev's
metrics too, so sub-4 adds a scrape, not a rewrite.

### DNS and the rename

Two grey-cloud A records for each of `argocd.mgryn.cc` and
`grafana.mgryn.cc`, one per worker. The workstation's `/etc/hosts` entry for
`argocd.mgryn.cc` moves to `dev-argocd.mgryn.cc` and dev's Ingress host and
the `argocd` role default change with it. Gatus gets a check per hub URL.

### Prod worker RAM

`pve` on 2026-10-03: 31.8G total, 6.1G available, 7.5G of swap free, with
the Talos nodes already running at 2G each. Two workers at 4G add 4G, which
leaves about 2G available. `claude-code` 8G to 6G is not needed and stays in
sub-4; it reboots the VM agent sessions run on.

Both workers resize in one `terraform apply`. The cluster is empty, so
rebooting both at once costs nothing; no workload is placed first. The
control plane stays at 2G.

## Failure modes

- **Sealed Vault.** AVP renders nothing and every prod Application with a
  `<path:...>` placeholder goes `Unknown` while Argo health stays `Healthy`.
  First check: `vault status` on `vault-02` (ADR 0004).
- **Bootstrap order.** The AVP ConfigMap and Secret must exist before the
  Helm deploy, or `argocd-repo-server` wedges in `Init`. The role keeps that
  order; so does the new playbook.
- **NFS down.** PVCs sit `Pending` and Prometheus and Grafana read as
  broken for unrelated reasons.
- **Certificates.** Debug issuance with the staging issuer; production
  allows 5 failed validations per hostname per hour.
- **A worker down.** Two A records still answer; Gatus alerts on the dead
  one.
- **Host RAM.** About 2G available after the resize. A guest OOM is a
  Proxmox-side event, so the swap and `available` figures are re-read after
  the apply. If prod grows, the next lever is shrinking `claude-code` or
  dev.
- **Resize plan.** Read the plan summary before the apply; a `destroy` is a
  stop (ADR 0013). A rename needs a `moved` block.

## Testing

No test suite, so each PR carries operator checks plus the repo's:
`scripts/check-manifests.sh`, `pre-commit run --all-files`, `terraform fmt
-check && terraform validate`, `ansible-lint`, and the prod `terraform test`
runs.

- **PR 1:** `kubectl get nodes` shows both workers with 4G; `showmount -e`
  on `nfs-01` lists the two worker addresses; `free -m` on `pve`.
- **PR 2:** `argocd.mgryn.cc` serves the login; `dev-argocd.mgryn.cc` still
  manages dev; a test AVP placeholder renders.
- **PR 3:** PVCs `Bound` on `nfs-prod`; valid certificates; a `curl` with
  the right `Host:` header returns 200 through each worker; Grafana's
  Prometheus datasource is healthy.
- **PR 4:** a test alert reaches Telegram; `data%` appears in Prometheus.

## Documentation

Each PR updates what it changes: the README table and diagram,
`docs/rebuild.md` for the bootstrap and DNS steps, and `docs/operations.md`
for the new URLs and the kubeconfig extraction. One ADR, 0024, records hub
placement, `kube-prometheus-stack` over the hand-rolled stack, and
pve-exporter for pool metrics; its number is renumbered at merge if another
branch lands first.

## Pull request shape

One spec, four implementation PRs, each verifiable alone. A merge is a
deploy, so the slices stay small.

1. **Host and nodes:** workers to 4G, `nfs-prod` clients, `kv-prod` seeds.
2. **Hub bootstrap:** `argocd-prod.yaml`, the CoreDNS entry, `root-prod`,
   `argocd-config` for prod, the dev rename.
3. **Platform apps:** NFS provisioner, cert-manager, ingress-nginx,
   `kube-prometheus-stack`, DNS records, Gatus checks.
4. **Alerting:** pve-exporter, rules, SLOs, Alertmanager routing.

This spec opens as a draft PR; the plan and implementation follow on the
same branch or later ones, per slice.

## Out of scope

- Registering dev as a spoke, ApplicationSets, Prometheus agent mode and
  retiring dev's ArgoCD (sub-project 4)
- jobboard in prod and the promotion flow (sub-project 5)
- Shrinking dev and `claude-code` (sub-project 4)
- Any workload other than the platform itself
