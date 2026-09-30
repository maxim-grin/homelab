# 0014. LAN services as one unprivileged LXC each, outside both clusters

**Status:** Accepted (2026-09-27)

## Context

Sub-project 1 of the hub-and-spoke roadmap (record
[0012](0012-hub-and-spoke-topology.md)) needed a home for Pi-hole,
Traefik, Glance, Gatus and LAN Orangutan. Gatus has to survive the things
it monitors; Pi-hole answers DNS for the whole LAN and cannot go down with
a cluster rebuild; LAN Orangutan scans with nmap and needs layer-2 access
to `vmbr0`, which a pod network hides; Traefik is being learned as an edge
proxy in front of Proxmox, Vault and both clusters.

## Decision

Run each as its own unprivileged Debian 13 LXC in
`terraform/environments/shared`, at `10.0.0.140`-`.144`, installed natively
by Ansible (no Docker) — about 1G of memory in total. Names are
`*.hl.mgryn.cc`, served through one DNS-only Cloudflare wildcard record
pointing at Traefik.

## Consequences

Putting them in `shared` rather than in-cluster keeps a `terraform
destroy` of either cluster from taking LAN DNS or monitoring down with it.
The cost is five more machines, native-installed rather than as
containers, each with its own Ansible role. `secret.yaml` carries their
credentials, same as every other host. The design's ~1G memory total for
the five LXCs did not hold: Gatus and Glance were each raised from 128M
to 256M after a single `apt` run OOM-killed the service running beside
one at 128M, putting the real total closer to 1.25G.

## Related

`docs/superpowers/specs/2026-09-27-lan-services-design.md`;
[#51](https://github.com/maxim-grin/homelab/pull/51) "feat: lan services";
`docs/superpowers/specs/2026-09-26-homelab-roadmap-design.md` "Why LAN
services sit outside both clusters".
