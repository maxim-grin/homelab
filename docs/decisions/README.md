# Architecture decision records

An ADR here is a short record of one decision this repository made: the
situation that forced it, what was chosen and what was rejected, and what
it costs. It exists so the reasoning behind a load-bearing choice — why
Vault moved off an LXC, why certificates use DNS-01 — survives longer than
the PR that made it. To add one: copy the shape of an existing record into
`docs/decisions/NNNN-kebab-title.md`, the next free number, and add it to
the table below in the same PR as the change it documents. To supersede
one: write a new record, then change the old one's Status line to
`Superseded by [NNNN](NNNN-....md) (YYYY-MM-DD)` — never delete or edit its
Context or Decision.

| #    | Decision                                                    | Status                          | Date       |
| ---- | ------------------------------------------------------------ | -------------------------------- | ---------- |
| [0001](0001-three-layers-three-tools.md) | Three layers, three tools | Accepted | 2026-09-08 |
| [0002](0002-ingress-nginx-daemonset.md) | ingress-nginx as a DaemonSet on host ports 80/443 | Accepted | 2026-09-08 |
| [0003](0003-nfs-default-storageclass.md) | NFS dynamic provisioning as the default StorageClass | Accepted | 2026-09-08 |
| [0004](0004-secrets-in-vault-via-avp.md) | Secrets in Vault, resolved at sync time by argocd-vault-plugin | Accepted | 2026-09-10 |
| [0005](0005-vault-lxc-for-secrets.md) | Vault in an LXC | Superseded by [0011](0011-vault-on-its-own-vm.md) | 2026-09-11 |
| [0006](0006-gitops-merge-is-the-deploy.md) | All work lands on `main` only through a merged pull request | Accepted | 2026-09-15 |
| [0007](0007-pin-image-tags-not-latest.md) | Pin image tags, never `:latest` | Accepted | 2026-09-15 |
| [0008](0008-acme-dns01-not-http01.md) | Certificates by ACME DNS-01 through Cloudflare, not HTTP-01 or Cloudflare's edge cert | Accepted | 2026-09-17 |
| [0009](0009-ci-reads-only-lint-blocks.md) | CI only reads, and any lint finding fails the build | Accepted | 2026-09-20 |
| [0010](0010-one-shared-nfs-server.md) | One shared NFS server, a disk per share, mounted by label | Accepted | 2026-09-22 |
| [0011](0011-vault-on-its-own-vm.md) | Vault on its own VM outside the cluster | Accepted, supersedes [0005](0005-vault-lxc-for-secrets.md) | 2026-09-25 |
| [0012](0012-hub-and-spoke-topology.md) | Hub and spoke: Talos prod hub, kubeadm dev spoke | Accepted, prod built (0021) | 2026-09-26 |
| [0013](0013-terraform-renames-need-moved-blocks.md) | Every Terraform rename carries a `moved` block | Accepted | 2026-09-27 |
| [0014](0014-lan-services-as-lxcs.md) | LAN services as one unprivileged LXC each, outside both clusters | Accepted | 2026-09-27 |
| [0015](0015-gatus-and-glance-over-alternatives.md) | Gatus + Telegram over Uptime Kuma; Glance over Homepage | Accepted (Glance not yet built) | 2026-09-27 |
| [0016](0016-traefik-as-lan-edge.md) | Traefik as the LAN edge, its own Cloudflare token, one ACME resolver rendered | Accepted | 2026-09-28 |
| [0017](0017-verify-lan-service-binaries-sha256.md) | Every LAN-service binary is verified by SHA-256 | Accepted | 2026-09-28 |
| [0018](0018-commit-msg-hook-enforces-rules.md) | Commit rules enforced by a commit-msg hook, not by review | Accepted | 2026-09-29 |
| [0019](0019-lxc-resolvers-1111-before-router.md) | LXC resolvers: `1.1.1.1` first, then the router, never Pi-hole | Accepted | 2026-09-30 |
| [0020](0020-pihole-opt-in-per-device.md) | Pi-hole is opt-in per device | Accepted | 2026-10-02 |
| [0021](0021-talos-prod-via-terraform-provider.md) | Talos prod cluster through the Terraform provider, secrets in state | Accepted | 2026-10-01 |
| [0022](0022-host-bootstrapped-by-script.md) | Proxmox host bootstrapped by one idempotent script | Accepted | 2026-10-01 |
| [0023](0023-renovate-hosted-app.md) | Renovate, as the hosted app, proposes pin updates | Accepted | 2026-10-01 |
