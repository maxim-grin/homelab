# 0005. Vault in an LXC

**Status:** Accepted (2026-09-11), superseded by [0011](0011-vault-on-its-own-vm.md) (2026-09-25)

## Context

Vault (record [0004](0004-secrets-in-vault-via-avp.md)) needed a home.
The design chose between in-cluster Helm, a full VM, and an unprivileged
Proxmox LXC.

## Decision

Run Vault as `vault-01`, an unprivileged LXC (vmid 104) in
`terraform/environments/dev`, using `modules/lxc`, with manual
single-share unsealing (`-key-shares=1 -key-threshold=1`) and
`/etc/hosts` pointing straight at it on port 8200.

## Consequences

Cheapest option to stand up, and it worked as the root of trust for every
`<path:...>` placeholder from 2026-09-14, when #10 merged the first
placeholders into `main`. It carried five weaknesses that
eventually forced its replacement: no backups (the `file` storage backend
has no consistent online backup), no TLS (every secret and the root token
crossed the LAN in clear text), no audit log, one KV namespace shared by
any future second cluster, and it lived in the `dev` Terraform root — a
prod cluster would have depended on a machine dev's `terraform apply`
could destroy. These five weaknesses are exactly what record 0011
addresses.

## Related

[#7](https://github.com/maxim-grin/homelab/pull/7) "Add Vault LXC";
`docs/superpowers/specs/2026-09-10-vault-avp-design.md`;
`docs/superpowers/specs/2026-09-25-vault-vm-design.md` "Problem"; superseded
by [#35](https://github.com/maxim-grin/homelab/pull/35)-[#43](https://github.com/maxim-grin/homelab/pull/43).
