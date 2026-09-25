# Vault on a VM — Design

Replace the `vault-01` LXC with a purpose-built VM in
`terraform/environments/shared`: Raft storage on its own disk, TLS from a
private CA, audit logging, separate `kv-dev/` and `kv-prod/` mounts with
per-cluster Kubernetes auth, and scheduled Raft snapshots to a dedicated NFS
share. The new machine is built alongside the old one and only takes over
once it is proven, so every step before the cutover is reversible by doing
nothing.

## Problem

`vault-01` (vmid 104, an unprivileged LXC in `terraform/environments/dev`) is
the root of trust for every Application carrying a `<path:...>` placeholder,
and it has five weaknesses:

**No backups.** Nothing snapshots it. The `file` storage backend has no
consistent online backup: you stop Vault and copy `/opt/vault/data`, or you
copy it running and hope. Today the only reason this is survivable is that
`secret.yaml`'s `vault_kv` block is the seed for everything in the store —
which stops being true the moment anything is written to Vault by hand.

**No TLS.** The listener is plain HTTP. Every secret AVP reads, and the root
token during seeding, crosses the LAN in clear text.

**No audit log.** Nothing records which identity read which secret, so no
question about access after the fact has an answer.

**One KV namespace.** Everything lives under `secret/`, and the `argocd-read`
policy grants `secret/data/*` — every secret in the store. A second cluster
sharing this Vault could read the first's secrets.

**It lives in the dev environment.** Prod would depend on a machine dev's
`terraform apply` owns, and `terraform/environments/prod` declares a second,
never-applied Vault (vmid 333) that would otherwise be stood up as a
duplicate root of trust.

## Decisions

| Question | Decision |
| --- | --- |
| One Vault or two | One, shared by both clusters |
| Container or VM | VM, `vault-02`, vmid 105, `10.0.0.133`, 2 cores, 2 GiB |
| Migration style | Build alongside, cut over, decommission the LXC same day |
| Address | New address, never reused; `10.0.0.132` retires with the LXC |
| Name | `vault.mgryn.cc`, used by every consumer; pinned in CoreDNS |
| Storage | Integrated Raft on a dedicated 10G disk |
| TLS | Private CA managed by Ansible, CA key on the workstation |
| Isolation | Separate `kv-dev/` and `kv-prod/` KV v2 mounts |
| Backups | Daily Raft snapshots to `/srv/nfs/backups` on `nfs-01`, 14 kept |
| Off-site copies | Out of scope — see Limitations |
| Landing | Five PRs |

The earlier branch `vault-shared` (PR #34), which moved the LXC into the
shared root with an `import` block, is superseded: a new VM needs no
adoption. It is closed unmerged and this spec replaces
`2026-09-23-vault-shared-design.md`.

## Limitations, stated plainly

Snapshots land on `nfs-01`, which is a VM on the same SSD as Vault itself.
This protects against a broken upgrade, a bad policy, a deleted secret or a
lost VM. **It does not protect against losing the SSD, the host, or the
building.** Off-site copies were considered and deliberately deferred: the
seed for everything in the store is already in `secret.yaml`, which is
committed encrypted and therefore exists wherever the repository is cloned.
That equivalence is the whole justification, and it holds only while nothing
is written to Vault that did not come from `vault_kv`. When that stops being
true, off-site backups stop being optional.

Every step also assumes one administrator and one physical failure domain.
Two Vaults on one mini-PC would double the unseal ritual and the patch
surface without isolating anything that matters.

## PR 1 — the VM exists

### `terraform/modules/vault-vm/`

A new module, following the `nfs-server` precedent: copied from `ubuntu-vm`,
every hard-coded setting identical (q35, `x86-64-v2-AES`,
`virtio-scsi-single`, cloud-init on `ide3`, serial, network), plus one data
disk.

- `scsi0` — OS disk, `disk_size`
- `scsi1` — `vault_data_disk_size`, for `/var/lib/vault`
- `automatic_reboot = false`, so a future in-place change can never bounce
  the root of trust unattended
- `lifecycle.ignore_changes = [power_state, clone, full_clone]`

### `terraform/environments/shared/`

`module "vault_vm"`: vmid **105**, name `vault-02`, pool `VM`, 2 cores,
2048 MB, `disk_size = "20G"`, `vault_data_disk_size = "10G"`,
`ip_config` from a new `vault_vm_ip` variable (`10.0.0.133/24`),
`start_at_node_boot = true`, `startup = "order=5,up=20"` — ahead of `nfs-01`
at order 10 and the cluster at 20/30.

No `import` block: the machine does not exist yet. The LXC is untouched.

`10.0.0.133` answered no ping and no ARP, but the router runs DHCP and its
pool has not been checked against the static block this repository assigns
(`.101`, `.110`, `.111`, `.130`, `.131`, `.132`, `.201`, `.202`). Confirming
that vmid 105 is free and that `.133` sits outside the pool is the first
operator step of PR 1; if the pool overlaps, the fix is to shrink it on the
router, which protects the eight addresses already in use rather than just
this one.

### Inventory

`ansible/inventories/shared/hosts.yaml` gains group `vault_vm` with host
`vault-02`. The existing `vault` group and its LXC stay exactly as they are,
so the old Vault keeps serving while the new one is built. The groups
collapse in PR 5.

`host_ips['vault-02']` and `proxmox_vm_ids['vault-02']` are added to
`secret.yaml` by the operator before the playbook runs.

## PR 2 — the backups share

### Terraform

`modules/nfs-server` gains `scsi3` (`nfs_backups_disk_size`, 10G), and the
shared root passes `"10G"`. The provider refuses to hot-attach a disk (it
demanded a reboot for `scsi1`/`scsi2`), so the operator attaches it with
`qm set 103 -scsi3 local-lvm:10,cache=none,discard=on,iothread=1,ssd=1` and
Terraform reconciles — no reboot of `nfs-01`.

### Ansible

A third entry in `nfs_server_shares`:

```yaml
  - name: backups
    device: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi3
    path: /srv/nfs/backups
    mode: "0700"
    clients: "{{ nfs_server_backup_clients }}"
```

with `nfs_server_backup_clients: "{{ ['vault-02'] | map('extract', host_ips) | list }}"`.

Two deliberate differences from the existing shares, both commented in the
defaults:

- **Exported to `10.0.0.133` only.** A Raft snapshot is every secret in one
  file; the only machine that needs to read it is the one that wrote it.
- **Mode `0700`, root-owned**, where the k8s shares are `0777`. The role
  gains a per-share `mode`, defaulting to `0777` so the existing shares are
  unchanged.

`RequiresMountsFor` gains `/srv/nfs/backups`.

## PR 3 — the new Vault, built and configured

The `vault` role targets `vault_vm` and is rebuilt around the VM.

### Storage and listener

```hcl
storage "raft" {
  path    = "{{ vault_data_dir }}"
  node_id = "vault-02"
}

listener "tcp" {
  address       = "{{ vault_listen_address }}"
  tls_cert_file = "{{ vault_tls_dir }}/server.crt"
  tls_key_file  = "{{ vault_tls_dir }}/server.key"
}

api_addr     = "https://{{ ansible_facts['default_ipv4']['address'] }}:{{ vault_api_port }}"
cluster_addr = "https://{{ ansible_facts['default_ipv4']['address'] }}:8201"

disable_mlock = true
```

`disable_mlock = true` stays, now for the documented reason rather than the
LXC one: HashiCorp advises disabling mlock with integrated storage, because
locking BoltDB's memory-mapped file defeats the point. The LXC capability
drop-in (`AmbientCapabilities`/`CapabilityBoundingSet`) is deleted — it
existed because the container could not grant `IPC_LOCK`, and a VM can.

### TLS

A new `tasks/tls.yaml`, using `community.crypto`:

- The CA private key and certificate live on the **workstation**, at
  `vault_ca_dir` (default `~/.homelab-ca/`), created on first run if absent.
  CA validity 10 years. The key never reaches the Vault host.
- A server key and CSR are generated on the VM; the CSR is signed on the
  workstation; the certificate is copied back. Validity 825 days, SANs
  `IP:10.0.0.133`, `DNS:vault-02`, `DNS:vault.mgryn.cc`.
- `ca.crt` is world-readable and safe to copy anywhere; it is what AVP and
  your CLI trust.
- Re-running the role reissues an expiring certificate. Losing the CA key
  means regenerating the CA and re-running — no data loss, but the
  `vault-ca` ConfigMap (PR 4) must be refreshed with it.

### Audit

A `file` audit device at `/var/log/vault/audit.log`, enabled in the
configure phase (it needs a token), with logrotate using `copytruncate`.

**If Vault cannot write its audit log it stops answering requests.** That is
Vault working as designed — an unauditable request is refused — and it is
recorded in the role's comments and in `CLAUDE.md`, because the symptom (a
healthy-looking Vault refusing everything) looks nothing like a full disk.

### Mounts, policies, auth

`kv-dev/` and `kv-prod/` as separate KV v2 mounts. Each cluster entry names
its own:

```yaml
vault_k8s_clusters:
  - name: dev
    kv_mount: kv-dev
    auth_path: kubernetes
    api_host: "{{ host_ips['master-01'] }}"
    control_plane_host: master-01
    policy_name: argocd-read
    role_name: argocd
    service_account_names: ["argocd-repo-server"]
    service_account_namespaces: ["argocd"]
```

Policy, per entry, with no wildcard spanning mounts:

```hcl
path "{{ cluster.kv_mount }}/data/*"     { capabilities = ["read"] }
path "{{ cluster.kv_mount }}/metadata/*" { capabilities = ["list", "read"] }
```

A `tasks/validate_clusters.yaml` refuses an entry missing any key, two
entries sharing an `auth_path` (the second would overwrite the first's
`kubernetes_host`, pointing one cluster's ArgoCD at the other's API server),
and two entries sharing a `kv_mount`.

The auth run delegates the CA and token-reviewer reads to
`cluster.control_plane_host`, which lives in the dev inventory, so it runs
with `-i inventories/shared -i inventories/dev`.

Seeding writes each mount named at the top of `vault_kv` (keyed by mount,
paths inside unchanged), writing a path only when its value differs;
adding an environment is a new top-level key.

### The name, and who resolves it

Consumers reach Vault as `https://vault.mgryn.cc:8200`, not by address. A
future move is then a DNS edit rather than an Ansible run and a pod rollout.

Two records, deliberately:

- **Cloudflare, DNS-only (grey cloud)**, `vault.mgryn.cc` → `10.0.0.133`,
  added by hand like `jobs.mgryn.cc`. It serves the workstation and anything
  else on the LAN. A private address in public DNS reveals a little about the
  internal layout; that is accepted.
- **A CoreDNS pin inside the cluster**, so AVP never depends on the WAN or on
  Cloudflare to find the root of trust. A new `coredns_hosts` Ansible role
  patches the `coredns` ConfigMap in `kube-system` with a `hosts` block
  mapping `10.0.0.133 vault.mgryn.cc`, then restarts the Deployment.

Ansible rather than ArgoCD owns that pin: Argo depends on Vault, so letting
Argo own the record that finds Vault is a loop that fails exactly when it is
needed. The caveat to record: a kubeadm upgrade can rewrite the `coredns`
ConfigMap, so the role is re-run after cluster upgrades, and the verification
step below is how you notice.

Terraform and Ansible keep using addresses. `secret.yaml` remains the record
of every host address and vmid, and Terraform has to assign the IP before
anything can resolve it.

### Snapshots

- An AppRole whose policy grants only `sys/storage/raft/snapshot`, with
  `role_id`/`secret_id` in `/etc/vault.d/snapshot.env`, mode 0600. Not the
  root token, and not a token that expires quietly.
- `/mnt/vault-backups` from `10.0.0.131:/srv/nfs/backups`, `nofail,_netdev`
  in `fstab`. `vault-02` starts at order 5, *before* `nfs-01` at order 10; a
  hard mount would stall its boot waiting for a server that is not up. The
  snapshot unit therefore asserts the mountpoint itself and fails loudly,
  rather than writing into an empty local directory and reporting success.
- A systemd service and daily timer: assert mountpoint, log in with the
  AppRole, `vault operator raft snapshot save`, prune beyond 14.

### Still manual, by design

`vault operator init` and every unseal. The role never sees the unseal key
or the root token; both stay in the password manager, as today.

## PR 4 — cutover

Two steps, one sitting:

1. **Ansible.** `argocd_vault_address` becomes `vault.mgryn.cc`, so
   `VAULT_ADDR` is `https://vault.mgryn.cc:8200`, and `argocd_avp_config`
   gains `VAULT_CACERT`. The CoreDNS pin from PR 3 is what resolves it. The CA certificate ships as a
   new `vault-ca` ConfigMap created by the `argocd` role from
   `{{ vault_ca_dir }}/ca.crt`, mounted into the avp sidecar, with a third
   `checksum/vault-ca` pod annotation. The existing two annotations exist
   because a ConfigMap or Secret change alone leaves a running sidecar on the
   old config at 2/2 Running; the CA needs the same treatment.
2. **Merge the manifests.** Five placeholders move to the new mount:

| File | Placeholder |
| --- | --- |
| `argocd/apps/cert-manager-issuers/dev/cloudflare-secret.yaml` | `<path:kv-dev/data/cert-manager/cloudflare#API_TOKEN>` |
| `argocd/apps/jobboard/dev/secret.yaml` | three under `kv-dev/data/jobboard/db` |
| `argocd/apps/jobboard/dev/ghcr-secret.yaml` | `<path:kv-dev/data/jobboard/ghcr#dockerconfigjson>` |

The two jobboard files move from `base/` into the `dev/` overlay: a
`kv-dev` path baked into a base that a prod overlay would also consume
defeats the separation.

**The window between the two steps is accepted, not eliminated.** AVP points
at the new Vault while the manifests still name `secret/`, so the three apps
report `ComparisonError` for one Argo poll plus the merge. Nothing goes down;
the last-applied resources keep running. Mirroring the old mount into the new
Vault would close the window at the cost of a transitional mount and a
temporarily widened policy — more moving parts than the problem deserves.

**The restore drill is part of this PR.** A snapshot from
`/srv/nfs/backups` is restored into a throwaway VM, unsealed, and a known
`kv-dev` value read back. An untested backup is a hypothesis.

## PR 5 — decommission, same day

`module "vault"` (vmid 104) is deleted from `terraform/environments/dev` and
destroyed — not released. Its contents exist in the new Vault and, for
everything that came from `vault_kv`, in `secret.yaml`. The `vault_vm` group
is renamed `vault`, the LXC's inventory entry goes, and every doc reference
with it. 1 GiB returns to the host.

Prod's duplicate Vault (`module "vault_lxc"`, vmid 333), its `vault_ip`
variable, its `vault_details` output and the `vault` group in
`inventories/prod` are deleted in the same PR: prod will authenticate against
`vault-02`.

## Documentation

- `CLAUDE.md` — `environments/shared/` holds `nfs-01` and `vault-02`; Vault
  is HTTPS with a private CA, reached as `vault.mgryn.cc` (a Cloudflare
  DNS-only record for the LAN, pinned in CoreDNS for the cluster, re-applied
  after a kubeadm upgrade); KV is split into `kv-dev/` and `kv-prod/` with
  per-mount policies; the placeholder form is `<path:kv-<env>/data/...>`;
  snapshots and where they land; and the audit-log-full behaviour.
- `docs/rebuild.md` — the `shared` apply creates `nfs-01` and `vault-02`;
  `~/.homelab-ca/` joins the workstation-files table as unrecoverable but
  regenerable; the vault playbook's invocations and their inventories; the
  snapshot and restore procedure.
- `ansible/README.md`, `terraform/README.md`, `README.md`.

## Verification

Per PR, beyond `terraform fmt`/`validate`/`tflint`, `ansible-lint`,
`pre-commit run --all-files` and `scripts/check-manifests.sh`:

- **PR 1**: the plan creates exactly one VM and changes nothing else;
  `qm config 105` shows both disks; SSH works; the LXC is untouched.
- **PR 2**: `showmount -e` lists `/srv/nfs/backups` for `10.0.0.133` only;
  the k8s shares are unchanged; `nfs-01` reboots with all three mounted.
- **PR 3**: `vault status` shows `raft` and unsealed; `openssl s_client
  -connect vault.mgryn.cc:8200 -CAfile ~/.homelab-ca/ca.crt` verifies the
  chain against the name, and the same against `10.0.0.133`; from a pod,
  `nslookup vault.mgryn.cc` answers `10.0.0.133` with the WAN unplugged;
  a read appears in the audit log; `vault kv get kv-dev/jobboard/db` matches
  the old Vault's values; the timer fires and a snapshot lands on the share;
  `vault-02` reboots cleanly **with `nfs-01` stopped**, proving `nofail`
  does not stall the boot.
- **PR 4**: the three apps `Synced`, their Secrets holding real values; a
  `kubectl exec` in the avp sidecar resolves `vault.mgryn.cc` and trusts the
  CA; the restore
  drill succeeds.
- **PR 5**: `pct status 104` gone; both Terraform roots plan clean; nothing
  in the repo references the LXC.

## Landing

Five PRs, in order, each with its own branch: `vault-vm`,
`nfs-backups-share`, `vault-role-rebuild`, `vault-cutover`,
`vault-lxc-decommission`. PRs 4 and 5 land the same day. PR #34 is closed
unmerged with a comment pointing here.

## Out of scope

- Off-site or encrypted-at-rest snapshot copies.
- Vault HA, multiple Raft peers, or auto-unseal.
- The prod cluster, its auth mount, its policies and its `kv-prod` contents.
- Vault's PKI, transit, or database engines.
- Migrating `secret.yaml` itself away from ansible-vault.
