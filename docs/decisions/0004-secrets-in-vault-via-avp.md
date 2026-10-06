# 0004. Secrets in Vault, resolved at sync time by argocd-vault-plugin

**Status:** Accepted (2026-09-10); partly superseded by [0026](0026-uniform-apps.md)

## Context

ArgoCD reads manifests from a public GitHub repository. A committed
Kubernetes Secret would put real credentials in public git history
permanently. Something has to keep the value out of the commit while
still letting ArgoCD apply the object that needs it.

## Decision

Store real secret values in HashiCorp Vault and commit only a `<path:...>`
placeholder in manifests; argocd-vault-plugin (AVP), running as an
`argocd-repo-server` sidecar, resolves them against Vault at sync time.
Rejected: External Secrets Operator, and a SOPS-encrypted
`vault/secrets.yaml.enc` for the seed (`ansible/secret.yaml`'s `vault_kv`
block was chosen instead). Vault itself first ran as an unprivileged
Proxmox LXC (record [0005](0005-vault-lxc-for-secrets.md)), rejecting
in-cluster Helm and a full VM at the time. At this point every secret
lived under one `secret/` path; the `kv-dev/data/...#FIELD` form, split
by environment, came later with record [0011](0011-vault-on-its-own-vm.md).

## Consequences

No secret value ever needs to touch git, and rotating one means writing to
Vault, not committing. The plugin is fragile at bootstrap: configured once
before it needed a `cmp-plugin` ConfigMap and an `argocd-vault-plugin-config`
Secret that nothing had created yet, and `argocd-repo-server` sat in `Init`
for six hours. `ansible/roles/argocd` now creates both before the Helm
deploy runs. A sealed Vault also fails silently — AVP renders nothing, sync
status goes `Unknown`, but Argo's health field still reports `Healthy`
because the last-applied resources are unchanged.

## Related

`docs/superpowers/specs/2026-09-10-vault-avp-design.md`; [#3](https://github.com/maxim-grin/homelab/pull/3),
[#10](https://github.com/maxim-grin/homelab/pull/10); CLAUDE.md "Secrets".
