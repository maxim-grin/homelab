# 0011. Vault on its own VM outside the cluster

**Status:** Accepted (2026-09-25). Supersedes [0005](0005-vault-lxc-for-secrets.md); partly superseded by [0026](0026-uniform-apps.md)

## Context

`vault-01`, the LXC from record [0005](0005-vault-lxc-for-secrets.md), had
five weaknesses: no backups (the `file` backend has no consistent online
backup), no TLS (secrets and the root token crossed the LAN in clear
text), no audit log, one KV namespace a second cluster could fully read,
and it lived in the `dev` Terraform root, so a future prod cluster would
depend on a machine dev's `terraform apply` owned.

## Decision

Replace it with `vault-02`, a purpose-built VM in
`terraform/environments/shared`: integrated Raft storage on its own data
disk, TLS from a private CA (`~/.homelab-ca/`, reached as
`vault.mgryn.cc`), audit logging to `/var/log/vault/audit.log`, separate
`kv-dev/`/`kv-prod/` mounts each read by only its own cluster's policy,
and daily Raft snapshots to a dedicated NFS share
(`/srv/nfs/backups`, mode 0700, exported only to `10.0.0.133`). The new
machine was built alongside the old one and only cut over once proven, in
five PRs, so every step before cutover was reversible by doing nothing;
the LXC was decommissioned the same day as cutover, after a restore drill
passed.

## Consequences

Vault now has real backups, TLS, an audit trail and cluster isolation —
but a restart still seals it (only a certificate renewal reloads it
without sealing), and a full root disk that stops Vault writing its audit
log looks like a healthy Vault answering nothing. Raft snapshots share the
same physical SSD as everything else, so they cover a bad upgrade or a
deleted secret, not a lost disk.

## Related

`docs/superpowers/specs/2026-09-25-vault-vm-design.md`;
[#35](https://github.com/maxim-grin/homelab/pull/35)-[#43](https://github.com/maxim-grin/homelab/pull/43);
CLAUDE.md vault bullets; README.md "What actually runs".
