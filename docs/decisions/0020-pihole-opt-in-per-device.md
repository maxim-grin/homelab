# 0020. Pi-hole is opt-in per device

**Status:** Accepted (2026-10-02)

## Context

The plan for sub-project 1 ended with a DHCP DNS cutover: the router
hands out Pi-hole's address to every device on the LAN. The router's
admin page cannot do that. It offers a DHCP address range and nothing
else: no DNS server to hand out, no upstream DNS field, and no way to turn
its DHCP server off so Pi-hole could take over. Record
[0014](0014-lan-services-as-lxcs.md) says only that Pi-hole answers LAN
DNS; record [0019](0019-lxc-resolvers-1111-before-router.md) covers the
containers' own resolvers (`1.1.1.1`, then the router, never Pi-hole),
not the LAN's clients.

## Decision

Pi-hole answers the devices that are pointed at `10.0.0.140` by hand, and
only those. Every other device keeps resolving through the router.

Rejected:

- Pi-hole's own DHCP server beside the router's. Clients accept whichever
  offer arrives first, so which DNS a device gets would be a race.
- Replacing or reflashing the router. It would work, but it is a hardware
  project of its own and does not belong in this one.
- A public secondary such as `1.1.1.1` on a device beside Pi-hole. The
  device may query either server at will, so some queries would bypass ad
  blocking and the local names.

## Consequences

A stopped Pi-hole takes name resolution away from the opted-in devices
only, not from the whole LAN. The rest of the LAN gets no ad blocking and
does not show up in Pi-hole's query log. Mitigations for the devices that
do use it:

- Pi-hole starts first: `startup = "order=1"` in
  `terraform/environments/shared/main.tf`.
- Gatus alerts on it within about two minutes (interval `1m`,
  `failure-threshold: 2`), resolving through `1.1.1.1` and the router,
  never Pi-hole.
- Undoing it on a device is setting its DNS back to automatic; see
  "Pointing a device at Pi-hole" in `docs/operations.md`.

If the router is ever replaced by one that can advertise a DNS server,
supersede this record with the LAN-wide cutover.

## Related

`docs/superpowers/specs/2026-09-27-lan-services-design.md`;
`ansible/roles/gatus/defaults/main.yaml`.
