# 0019. LXC resolvers: `1.1.1.1` first, then the router, never Pi-hole

**Status:** Accepted (2026-09-30)

## Context

The LAN services LXCs (record [0014](0014-lan-services-as-lxcs.md)) needed
their own DNS resolution, separate from Pi-hole, which they run alongside.
Gatus sends alerts through Telegram, which needs DNS, and Traefik renews
its certificate through Cloudflare, which needs DNS — if either resolved
through Pi-hole, a dead Pi-hole would silence the alert about itself.

## Decision

Resolve through `1.1.1.1` first, then the router; never Pi-hole. The
order matters: the router's DNS rebind protection answers a public name
that points at a private address — `vault.mgryn.cc`, every
`*.hl.mgryn.cc` — with an empty `NOERROR`, which a resolver takes as
final, so with the router queried first none of those names would resolve
at all.

## Consequences

Found the hard way, not in planning: Gatus's first live run reported
`lookup vault.mgryn.cc on 10.0.0.1:53: no such host`, because the LXCs had
originally been configured with the router's resolver ahead of
`1.1.1.1`. The fix is resolver order alone — no Pi-hole change, no DNS
record change — and every affected LXC needed a reboot to pick it up.

## Related

`docs/superpowers/specs/2026-09-27-lan-services-design.md` "Why no Pi-hole
for the LXCs themselves"; [#56](https://github.com/maxim-grin/homelab/pull/56)
"feat: add the gatus role"; `terraform/environments/shared/main.tf`.
