# Homelab Roadmap — Design

Turn the one-cluster homelab into a hub-and-spoke pair — a Talos prod
cluster that runs ArgoCD and monitoring for both clusters, and a
disposable kubeadm dev cluster — plus a set of LAN services in LXC
containers, all inside the host's existing 31G of RAM.

This document fixes the shape and the order. Each numbered sub-project
below gets its own design, plan and pull request; nothing here is
implemented by this document alone.

## Goal

Learning Kubernetes, ArgoCD, Prometheus and Grafana on real
infrastructure. Where two designs work equally well, the one that
teaches more of those wins. The layout in `terraform/environments/prod`
is not a requirement.

Success looks like:

- one ArgoCD UI showing both clusters' Applications
- one Grafana showing metrics from both clusters
- a change merged to `main` reaches dev, is tested there, and reaches
  prod only through a second pull request
- dev can be destroyed and rebuilt without losing anything
- Pi-hole, Traefik, Glance, Gatus and LAN Orangutan running on the LAN,
  Glance showing Proxmox and every service

## Constraints

- **31G of RAM, no upgrade.** `free -g` on `pve` on 2026-09-26: 31G
  total, 7G available, 1G of swap already in use. Existing VMs are
  allocated 28G.
- **ArgoCD syncs `main`.** Anything that separates dev from prod has to
  live inside `main`, not on another revision.
- **Harbor and Gitea are unused.** jobboard pulls
  `ghcr.io/maxim-grin/jobboard`; nothing pulls from Harbor.

## Decisions

| Question | Decision |
| --- | --- |
| Prod distribution | Talos, from a `talos-tp` template |
| Dev distribution | kubeadm on Ubuntu, as today |
| ArgoCD topology | One ArgoCD, in prod, managing both clusters |
| Monitoring topology | Prometheus and Grafana in prod; Prometheus in agent mode on dev, remote-writing to prod |
| Dev's role | Workloads only; rebuilt freely, re-registered with the hub |
| Promotion | Dev overlays track the latest version, prod overlays pin a tag; promotion is a PR bumping the pin |
| LAN services | Pi-hole, Traefik, Glance, Gatus, LAN Orangutan ([design](2026-09-27-lan-services-design.md)) |
| Where LAN services run | One unprivileged LXC each, native install via Ansible, no Docker |
| Terraform root for LXCs | `environments/shared`, beside `nfs-01` and `vault-02` |
| Harbor, Gitea | Removed |
| Control-plane scheduling | Allowed on dev (one worker); prod keeps a dedicated control plane |

### Why hub and spoke

Two self-contained clusters would each carry an ArgoCD (~1G) and a
kube-prometheus-stack (~2G): about 6G of duplicates on a host with 7G
free, and the same thing learned twice. One ArgoCD managing two
clusters teaches cluster registration, ApplicationSets with a cluster
generator, and per-cluster overlays; one Grafana over two Prometheus
sources teaches remote write. A dev cluster with no controllers of its
own is also what makes it disposable: rebuild, register, and the
ApplicationSet puts everything back.

The cost: dev cannot deploy while prod is down, and dev's current
ArgoCD has to be retired.

### Why LAN services sit outside both clusters

Gatus has to survive the things it monitors. Pi-hole answers DNS
for the whole LAN and cannot go down with a cluster rebuild. LAN
Orangutan scans with nmap and needs layer-2 access to `vmbr0` to see
MAC addresses, which a pod network hides. Traefik is the thing being
learned as an edge proxy in front of Proxmox, Vault and both clusters.
Putting them in `shared` keeps a `terraform destroy` of either cluster
from taking LAN DNS with it.

### Why pinned overlays for promotion

It extends the version pinning jobboard already has
([2026-09-15 design](2026-09-15-jobboard-version-pinning-design.md)),
keeps every promotion reviewable and revertible as a PR, and needs no
extra software. A Git revision per environment was rejected because it
moves prod outside PR review and splits platform changes across two
revisions.

## Memory budget

| Machine | Today | Target |
| --- | --- | --- |
| Proxmox host | ~2G | ~2G |
| `nfs-01`, `vault-02` | 2G + 2G | 2G + 2G |
| `claude-code` | 8G | 6G |
| dev control plane | 8G | 3G |
| dev workers | 2 × 4G | 1 × 3G |
| prod control plane | — | 2G |
| prod workers | — | 2 × 4G |
| Pi-hole, Traefik, Glance, Gatus, LAN Orangutan | — | about 1.25G total |
| **Total** | **~30G** | **~29G** |

Prod gets two workers on purpose: drains, PodDisruptionBudgets,
anti-affinity and rolling updates teach nothing on one node.

Gatus and Glance went from 128M to 256M in PR 4, once rehearsal showed
128M left no headroom for an Ansible module run alongside the service.

Only 7G is free today, and prod plus the LXCs need about 11G, so dev
shrinks in two steps — part of it before prod exists (sub-project 0),
the rest once dev no longer runs ArgoCD (sub-project 4).

## Disk budget

`local-lvm` is a 141G thin pool, 55G written (39%) on 2026-09-26, with
about 293G already allocated to guests. The three Talos VMs (3 × 20G)
and five LXCs (5 × 8G) add 100G of allocation but about 20G of actual
writes: roughly 75G of 141G used, allocation near 2.8× the pool.

That fits, but a thin pool that reaches 100% gives every guest I/O
errors at once. Three rules follow, each owned by a sub-project:

- Prometheus in prod gets a `retention.size` well under the `nfs-prod`
  disk (sub-project 3).
- Space freed inside a guest returns to the pool only through discard:
  check `discard=on` and `fstrim` when Harbor's data is deleted
  (sub-project 0).
- The pool's `data%` is scraped and alerts at 80% (sub-project 3).

## Sub-projects

Each gets its own design at the weight it needs, and its own PR or PRs.

**0. Make room.** Remove Harbor and Gitea — Applications, app
directories, `cluster_secrets` entries, and mentions in `README.md`,
`CLAUDE.md` and `docs/rebuild.md` (past specs and plans stay as
history). Lower the dev control plane 8G → 4G and the dev workers 4G →
3G. Frees 6G. Bounded: design in chat, no spec.

**1. LAN services.** Five LXCs in `environments/shared`, an Ansible role
each, Traefik routes by hostname (the domain is chosen there), Glance widgets for Proxmox
and every service. Pi-hole becomes the router's DNS.

**2. Prod Talos cluster.** Fix the prod root's provider and Terraform
pins (`3.0.2-rc04` conflicts with `modules/talos-vm`'s `3.0.2-rc10`),
build the `talos-tp` template and `Talos-K8s` pool, replace the
old LXC modules in `environments/prod/main.tf`, and generate Talos
machine configs without committing their secrets. Done when `kubectl get
nodes` shows three Ready nodes. Renovate covers
`terraform/environments/prod` too: the `ignorePaths` entries in
`renovate.json5` were removed when this was done (ADR 0023).

**3. Prod platform hub.** ArgoCD in prod, AVP reading `kv-prod`,
`nfs-prod` export and StorageClass, cert-manager, ingress,
kube-prometheus-stack with Grafana, and Prometheus alerting rules
and SLOs for both clusters (including the pool `data%` alert above).

**4. Dev becomes a spoke.** Register dev with prod's ArgoCD,
ApplicationSets for dev's workloads, retire dev's ArgoCD, Prometheus
agent remote-writing to prod, shrink dev to one 3G control plane and
one 3G worker, shrink `claude-code` 8G → 6G, and a rebuild that is one
Terraform apply plus one playbook. Resizing `claude-code` reboots
the VM that agent sessions run on, so it is a targeted apply from the
workstation while no session is running.

The rebuild also renames the VMs, which are `ubuntu-k8s-master-01` and
`ubuntu-k8s-worker-01` today, to `kubeadm-dev-cp1` and `kubeadm-dev-w1`,
the `<distro>-<env>-<role>` pattern prod uses (`talos-prod-cp1`). A
rename done in place would leave the Proxmox name, the guest hostname and
the kubeadm node name disagreeing, and needs `moved` blocks (ADR 0013);
creating the VMs fresh under the new names avoids both.

Rebuilding dev from scratch is acceptable here, with one exception:
jobboard's Postgres, the only state dev holds that git does not. It lives
on an `nfs-dev` PVC, which is deleted with the PVC, so it is dumped
(`pg_dump`) off the cluster before the rebuild and restored into prod's
Postgres in sub-project 5, which reuses the data. The dump goes to the
operator's workstation, not to `nfs-01`: a copy on the same disk survives
neither the SSD nor a rebuild drill. The sub-4 brainstorm may therefore
reopen the "kubeadm on Ubuntu" decision above and look for a better dev
distribution, since the rename and the rebuild already replace the VMs.

**5. jobboard in prod.** Prod overlay pinned to a tag, the dev-to-prod
promotion flow, and `jobs.mgryn.cc` moved to prod.

0 comes first because nothing else fits in memory without it. 1 and 2
are independent of each other. 3 needs 2; 4 needs 3; 5 needs 4.

## Deferred

- **Kargo** as a promotion engine, once pinned-overlay promotion works.
- **Argo CD Image Updater** to bump dev's version automatically.
- **Cloudflare Tunnel** for public access without open ports.
- **Off-site backup.** Vault snapshots and NFS data sit on the same SSD
  as everything else, so a dead disk still loses them. Not in scope,
  and still the largest open risk.
- **n8n.**
- **New 1TB SSD.** Installed after this roadmap lands: as a second disk
  for the NFS shares and Vault snapshots if the chassis has a free slot
  — which also closes most of the backup risk above — otherwise as a
  replacement, rebuilt from `docs/rebuild.md` as a drill.
