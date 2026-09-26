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
came with the repository from its original author and is not a
requirement.

Success looks like:

- one ArgoCD UI showing both clusters' Applications
- one Grafana showing metrics from both clusters
- a change merged to `main` reaches dev, is tested there, and reaches
  prod only through a second pull request
- dev can be destroyed and rebuilt without losing anything
- Pi-hole, Traefik, Homepage, Uptime Kuma and LAN Orangutan running on
  the LAN, Homepage showing Proxmox and every service

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
| LAN services | Pi-hole, Traefik, Homepage, Uptime Kuma, LAN Orangutan |
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

Uptime Kuma has to survive the things it monitors. Pi-hole answers DNS
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
| Pi-hole, Traefik, Homepage, Uptime Kuma, LAN Orangutan | — | ~1.5G total |
| **Total** | **~30G** | **~28.5G** |

Prod gets two workers on purpose: drains, PodDisruptionBudgets,
anti-affinity and rolling updates teach nothing on one node.

Only 7G is free today, and prod plus the LXCs need about 11.5G, so dev
shrinks in two steps — part of it before prod exists (sub-project 0),
the rest once dev no longer runs ArgoCD (sub-project 4).

## Sub-projects

Each gets its own design at the weight it needs, and its own PR or PRs.

**0. Make room.** Remove Harbor and Gitea — Applications, app
directories, `cluster_secrets` entries, and mentions in `README.md`,
`CLAUDE.md` and `docs/rebuild.md` (past specs and plans stay as
history). Lower the dev control plane 8G → 4G and `claude-code` 8G →
6G. Frees about 6G. Bounded: design in chat, no spec.

**1. LAN services.** Five LXCs in `environments/shared`, an Ansible role
each, Traefik routes by hostname (the domain is chosen there), Homepage widgets for Proxmox
and every service. Pi-hole becomes the router's DNS.

**2. Prod Talos cluster.** Fix the prod root's provider and Terraform
pins (`3.0.2-rc04` conflicts with `modules/talos-vm`'s `3.0.2-rc10`),
build the `talos-tp` template and `Talos-K8s` pool, replace the
author's LXC modules in `environments/prod/main.tf`, and generate Talos
machine configs without committing their secrets. Done when `kubectl get
nodes` shows three Ready nodes.

**3. Prod platform hub.** ArgoCD in prod, AVP reading `kv-prod`,
`nfs-prod` export and StorageClass, cert-manager, ingress,
kube-prometheus-stack with Grafana.

**4. Dev becomes a spoke.** Register dev with prod's ArgoCD,
ApplicationSets for dev's workloads, retire dev's ArgoCD, Prometheus
agent remote-writing to prod, shrink dev to one 3G control plane and
one 3G worker, and a rebuild that is one Terraform apply plus one
playbook.

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
