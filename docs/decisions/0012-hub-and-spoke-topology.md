# 0012. Hub and spoke: Talos prod hub, kubeadm dev spoke

**Status:** Accepted (2026-09-26); prod built per [0021](0021-talos-prod-via-terraform-provider.md)

## Context

The homelab is one cluster today, on a host with about 31G of RAM. Two
fully self-contained clusters would each carry an ArgoCD (~1G) and a
kube-prometheus-stack (~2G) — about 6G of duplicates on a host with 7G
free, and the same thing learned twice.

## Decision

Turn it into a hub-and-spoke pair: prod runs Talos, from a `talos-tp`
template, and hosts the one ArgoCD (managing both clusters) and the one
Prometheus/Grafana (dev runs Prometheus in agent mode, remote-writing to
prod). Dev stays kubeadm on Ubuntu, workloads only, rebuilt freely and
re-registered with the hub. Promotion between them extends the pinned-tag
model already used for jobboard (record
[0007](0007-pin-image-tags-not-latest.md)): dev overlays track latest,
prod overlays pin a tag, and a PR bumps the pin — rejected a Git revision
per environment, which moves prod outside PR review and splits platform
changes across two revisions. The work splits into six sub-projects, each
with its own design and PR.

## Consequences

One ArgoCD teaches cluster registration and per-cluster overlays; the
cost is dev cannot deploy while prod is down, and dev's current ArgoCD has
to be retired. Sub-project 2 built the prod cluster
([0021](0021-talos-prod-via-terraform-provider.md)), and CI now validates
`prod` with the other two roots.

## Related

`docs/superpowers/specs/2026-09-26-homelab-roadmap-design.md`;
[#44](https://github.com/maxim-grin/homelab/pull/44),
[#46](https://github.com/maxim-grin/homelab/pull/46).
