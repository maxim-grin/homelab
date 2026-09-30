# 0002. ingress-nginx as a DaemonSet on host ports 80/443

**Status:** Accepted (2026-09-08)

## Context

The cluster is bare metal: one Proxmox host, kubeadm, no cloud load
balancer and no MetalLB. A `Service` of type `LoadBalancer` has nothing to
provision it, and would sit `Pending` forever.

## Decision

Run ingress-nginx as a DaemonSet bound to host ports 80 and 443 on every
node, rather than as a ClusterIP or LoadBalancer Service. Any node's IP
then answers HTTP/HTTPS directly for whichever Ingress-routed hostname a
client asks for.

## Consequences

There is no single stable cluster IP for ingress — clients reach any node,
and most hostnames resolve through `/etc/hosts` on the workstation to a
node IP rather than through real DNS, since there is no DNS server on the
LAN. `jobs.mgryn.cc` is the one exception, a DNS-only Cloudflare record
pointing at a node IP so it resolves anywhere on the LAN. This constrains
every service exposed through ingress to living behind a hostname rather
than a dedicated IP, and it means "Argo says Healthy" is not proof of
reachability — a Deployment can be up with no ingress controller answering
for it at all, which is exactly what happened to Harbor.

## Related

CLAUDE.md, "ingress-nginx is a DaemonSet on host ports 80/443"; README.md
"What actually runs" and "Diagram"; `argocd/apps/ingress-nginx`.
