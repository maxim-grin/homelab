# 0015. Gatus + Telegram over Uptime Kuma; Glance over Homepage

**Status:** Accepted (2026-09-27) — Gatus built 2026-09-30; Glance not yet
built

## Context

The LAN services design (record
[0014](0014-lan-services-as-lxcs.md)) needed an uptime monitor and a
dashboard.

## Decision

Gatus replaces Uptime Kuma: monitors live in YAML rather than a database,
and it exposes a `/metrics` endpoint; it alerts to Telegram on failure and
recovery. Glance replaces Homepage: about 30M of memory instead of about
1G, and a single Go binary.

## Consequences

Gatus checks the Proxmox UI, NFS, Vault, Pi-hole DNS, every `*.hl` name
with its certificate, `jobs.mgryn.cc` and the router, alerting on 2
consecutive failures or successes at 1-minute intervals, with history in
SQLite. Because Gatus and Traefik resolve through `1.1.1.1` rather than
Pi-hole (record [0019](0019-lxc-resolvers-1111-before-router.md)), a dead
Pi-hole cannot silence the alert about itself. Glance's design already
covers both of its unverified cases at planning time — a `dns-stats`
widget against Pi-hole v6's application password, and a `custom-api`
widget for the Proxmox token header — so Homepage was never needed as a
fallback; Glance itself is still planned, not deployed.

## Related

[#51](https://github.com/maxim-grin/homelab/pull/51) "feat: lan services"
(description: Gatus/Glance rationale); [#56](https://github.com/maxim-grin/homelab/pull/56)
"feat: add the gatus role".
