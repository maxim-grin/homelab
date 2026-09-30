# 0016. Traefik as the LAN edge, its own Cloudflare token, one ACME resolver rendered

**Status:** Accepted (2026-09-28)

## Context

`*.hl.mgryn.cc` needed an edge proxy in front of Pi-hole, Proxmox and the
Traefik dashboard itself, with its own trusted certificate, separate from
cert-manager's DNS-01 setup for `jobs.mgryn.cc` (record
[0008](0008-acme-dns01-not-http01.md)).

## Decision

Traefik v3 on its own LXC (`10.0.0.141`), fetched from the release archive
and checked against its published checksums, running as the `traefik`
user with `CAP_NET_BIND_SERVICE`. It gets a wildcard certificate (`hl.mgryn.cc`
+ `*.hl.mgryn.cc`) by DNS-01 through Cloudflare, using its own token in
`/etc/traefik/traefik.env` (root, 0600, `no_log`) — a separate credential
from cert-manager's, so either can be revoked without touching the other.
`traefik_cert_resolver` selects `letsencrypt` or `letsencrypt-staging`, and
only the selected resolver is configured; the other's stored certificates
are removed, because Traefik loads every configured resolver's
certificates into one shared store and would otherwise risk serving a
staging certificate in production.

## Consequences

A route change reloads Traefik without restarting it; a static-config or
unit change restarts it. `readTimeout: 0` on `:443` was needed because v3's
default 60-second timeout cuts off ISO uploads and Proxmox consoles. The
plan's HTTP→HTTPS redirect check (308) was wrong — rehearsal found 301.

## Related

`docs/superpowers/plans/2026-09-27-lan-services-foundation.md`;
[#54](https://github.com/maxim-grin/homelab/pull/54) "feat: add the traefik
role"; `ansible/roles/traefik`.
