# 0020. Pi-hole is the LAN's only DNS server

**Status:** Accepted (2026-10-01)

## Context

The DHCP DNS cutover is the last step of sub-project 1 (PR 6): the
router hands out Pi-hole's address to every device on the LAN. Record
[0014](0014-lan-services-as-lxcs.md) says only that Pi-hole answers LAN
DNS; record [0019](0019-lxc-resolvers-1111-before-router.md) covers the
containers' own resolvers (`1.1.1.1`, then the router, never Pi-hole),
not the LAN's clients.

## Decision

The router's DHCP DNS is `10.0.0.140` alone, with no secondary.

Rejected: a public secondary such as `1.1.1.1` beside it. Clients may
query either server at will, so some queries would bypass ad blocking
and the local names, which defeats the point of Pi-hole.

## Consequences

Pi-hole is a single point of failure for name resolution on every LAN
device. Mitigations:

- Pi-hole starts first: `startup = "order=1"` in
  `terraform/environments/shared/main.tf`.
- Gatus alerts on it within about two minutes (interval `1m`,
  `failure-threshold: 2`), resolving through `1.1.1.1` and the router,
  never Pi-hole.
- Rollback: set the router's DHCP DNS back to the setting recorded in
  the "DNS cutover rollback" section of `docs/operations.md`, then renew
  leases.

## Related

`docs/superpowers/specs/2026-09-27-lan-services-design.md`;
`ansible/roles/gatus/defaults/main.yaml`.
