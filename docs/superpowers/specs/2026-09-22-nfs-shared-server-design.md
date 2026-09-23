# Shared NFS Server — Design

Move `nfs-01` out of the `dev` environment into a new `shared` Terraform
root and Ansible inventory, and give it two independent shares — `nfs-dev`
and `nfs-prod` — each on its own virtual disk and exported only to its own
cluster's nodes.

## Problem

`nfs-01` (vmid 103) is declared in `proxmox/environments/dev/main.tf` and
listed in `ansible/inventories/dev`. It serves one export,
`/srv/nfs/k8s`, from its 20G OS disk to all of `10.0.0.0/24`. That has
three consequences:

**dev owns storage prod would need.** A future prod cluster's volumes would
live on a machine that dev's `terraform apply` can change or destroy.

**Nothing separates the environments.** One directory, one free-space pool,
one client list. Anything on the LAN can mount any volume.

**A full share takes the VM down with it.** PVC data and the OS share one
filesystem. `nfs-subdir-external-provisioner` does not enforce PVC sizes, so
Prometheus or Harbor can fill the root disk.

## Decisions

| Question | Decision |
| --- | --- |
| Where the server lives in Terraform | New root `proxmox/environments/shared/`, own local state and tfvars |
| Share isolation | One virtual disk per share (`scsi1` dev, `scsi2` prod) |
| Existing VM | Adopted in place — same vmid 103, same IP `10.0.0.131` |
| Export clients | Exact node IPs per share, from `host_ips` |
| Disk sizes | 50G dev, 50G prod; OS disk stays 20G |
| Module | Dedicated `modules/nfs-server`, not a change to `ubuntu-vm` |
| Dev share path | Stays `/srv/nfs/k8s` — existing PVs have it baked in |

Prod is scaffolding that has never been applied. This design extends it
deliberately, and only as far as the prod provisioner manifest.

## Terraform

### `proxmox/modules/nfs-server/`

A copy of `modules/ubuntu-vm` trimmed to the variables the NFS server uses,
with two fixed data disks added:

- `scsi0` — OS disk, `disk_size`, as in `ubuntu-vm`
- `scsi1` — `nfs_dev_disk_size`, on `disk_storage`
- `scsi2` — `nfs_prod_disk_size`, on `disk_storage`

Same `proxmox_vm_qemu` settings as `ubuntu-vm` (q35, `x86-64-v2-AES`,
`virtio-scsi-single`, cloud-init, qemu agent). The resource is named
`nfs_server`.

`lifecycle.ignore_changes` carries `power_state` as `ubuntu-vm` does, plus
`clone` and `full_clone`. An imported VM need not report the template it was
cloned from, and a clone mismatch is what would make Terraform plan a
replacement — which would destroy the OS disk.

Fixed disks, not a list: YAGNI. A third share is a module change.

### `proxmox/environments/shared/`

New root. `versions.tf` pins the same `required_version = "~> 1.16.0"` and
`telmate/proxmox` `3.0.2-rc10` as dev. Local state.

Files: `versions.tf`, `main.tf`, `variables.tf`, `outputs.tf`,
`shared.tfvars.example`, `backend.tf.example`. `shared.tfvars` is created by
hand and must be gitignored — confirm with
`git check-ignore -v proxmox/environments/shared/shared.tfvars`, do not
assume the existing rule matches.

`module "nfs"`: vmid 103, name `nfs`, pool `VM`, 2 cores, 2048 MB,
`disk_size = "20G"`, `nfs_dev_disk_size = "50G"`,
`nfs_prod_disk_size = "50G"`, `disk_storage = "local-lvm"`,
`start_at_node_boot = true`, `startup = "order=10,up=30"` — the dev cluster's
startup order (`dev/main.tf`, master `order=20`, workers `order=30`) assumes
NFS comes up first.

```hcl
import {
  to = module.nfs.proxmox_vm_qemu.nfs_server
  id = "${var.pm_target_node}/qemu/103"
}
```

Outputs: `nfs_vm_details`, moved from dev.

### `proxmox/environments/dev/`

Delete `module "nfs"`, output `nfs_vm_details` and variable `nfs_vm_ip`
(and its line in `dev.tfvars.example`). Add:

```hcl
removed {
  from = module.nfs
  lifecycle {
    destroy = false
  }
}
```

The startup-order comments in dev's `main.tf` that name `nfs-01` stay true;
update them to say it lives in `shared/`.

### Apply order and gates

1. **Pre-flight** — `pvesm status` on the host: `local-lvm` is `lvmthin` and
   has room for 100G more. Stop if not.
2. **dev plan** — exactly one resource removed from state without being
   destroyed; `0 to add, 0 to change, 0 to destroy`. Anything else, stop.
3. **dev apply.**
4. **shared plan** — `1 to import`, one in-place update adding `scsi1` and
   `scsi2`, `0 to destroy`, no replacement. A replacement means the module
   does not match the live VM: fix the module until the plan is a pure
   add-disks update. Never apply a plan that replaces vmid 103.
5. **shared apply.**

Between steps 3 and 5 no state owns `nfs-01`; the VM keeps running
unchanged.

## Ansible

### Inventory

New `ansible/inventories/shared/hosts.yaml` with group `nfs` holding
`nfs-01` (`ansible_host: "{{ host_ips['nfs-01'] }}"`,
`proxmox_vm_id: "{{ proxmox_vm_ids['nfs-01'] }}"`), plus whatever
`group_vars/all.yaml` values the `nfs_server` role and `ansible_user` need.
`nfs-01` and the `nfs` group are removed from `inventories/dev/hosts.yaml`.
`secret.yaml` is unchanged.

`playbooks/nfs_server.yaml` is unchanged; it now runs with
`-i inventories/shared`. `nfs_setup.yaml` (the client half) still runs
against `inventories/dev`; `nfs_server_ip` does not change.

### `nfs_server` role

One export becomes a list of shares:

```yaml
nfs_server_shares:
  - name: dev
    device: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
    path: /srv/nfs/k8s
    clients: "{{ nfs_server_dev_clients }}"
  - name: prod
    device: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2
    path: /srv/nfs/prod
    clients: "{{ nfs_server_prod_clients }}"

nfs_server_dev_clients: "{{ ['master-01', 'worker-01', 'worker-02'] | map('extract', host_ips) | list }}"
nfs_server_prod_clients: []
nfs_server_export_options: rw,sync,no_subtree_check,no_root_squash
```

The dev path is `/srv/nfs/k8s`, not `/srv/nfs/dev`, and the defaults file
says why: every existing PV carries
`nfs.path: /srv/nfs/k8s/<ns>-<pvc>-<pv>`, that field is immutable, and
`nfs-dev` has `reclaimPolicy: Delete` with `archiveOnDelete: "false"`.
Renaming the path would mean hand-recreating every PV.

Per share, in order:

1. **Guard.** If `path` exists, is not a mount point, and is not empty,
   fail and name the path. Without this, a run before the data migration
   mounts an empty disk over live PVC data.
2. `community.general.filesystem` — ext4, label `nfs-<name>`, only if the
   device has no filesystem.
3. `ansible.posix.mount` — by `LABEL=nfs-<name>`, `state: mounted`, into
   `fstab`. No `nofail`.
4. Directory mode `0777`, existing comment kept.

Then:

- A systemd drop-in for `nfs-server.service` with
  `RequiresMountsFor=/srv/nfs/k8s /srv/nfs/prod`. A missing disk stops
  NFS loudly instead of exporting the empty directory underneath the mount
  point, where writes would land silently on the OS disk.
- `templates/exports.j2` loops over the shares and **skips any share whose
  `clients` is empty**. An exports line with no client list exports to
  everyone.

Collections: `community.general` and `ansible.posix` are already in
`requirements.yml`.

## Migration

Run by hand on `nfs-01`, after the shared apply, before the role run.

1. In ArgoCD, disable auto-sync on `nfs`, gitea, harbor, monitoring and
   jobboard — `selfHeal: true` would otherwise scale them back. Scale their
   stateful workloads and the provisioner to 0.
2. `mkfs.ext4 -L nfs-dev` the `scsi1` device, mount it at `/mnt/nfs-dev`,
   `rsync -aHAX --numeric-ids /srv/nfs/k8s/ /mnt/nfs-dev/`. Compare file
   counts and `du` totals. Unmount `/mnt/nfs-dev`.
3. `systemctl stop nfs-server`, `mv /srv/nfs/k8s /srv/nfs/k8s.old`,
   `mkdir /srv/nfs/k8s`.
4. Run `playbooks/nfs_server.yaml -i inventories/shared`. The filesystem
   task leaves the labelled disk alone, the guard passes on the empty
   directory, the role mounts both disks, writes `fstab`, the drop-in and
   `/etc/exports`, and starts `nfs-server`.
5. `showmount -e`, scale everything back up, re-enable auto-sync.
6. Keep `/srv/nfs/k8s.old` for a week, then delete it.

## Prod

`argocd/apps/nfs_provisioner/prod/deployment.yaml`: replace `<server>` with
`10.0.0.131` and `<path>` with `/srv/nfs/prod`. No `root-prod` Application
exists, so nothing syncs it.

`proxmox/environments/prod/main.tf` is untouched. Its `tk_nas` LXC (vmid 300)
overlaps with this design; remove or repurpose it when prod is built.

## Documentation

- `docs/rebuild.md` — `shared` apply before dev; `nfs_server.yaml` with
  `-i inventories/shared`; `shared.tfvars` in the unrecoverable-files table.
- `CLAUDE.md` — Layout and "how a change reaches the cluster" name
  `shared/`; the `*.tfvars` bullet names `shared.tfvars`; a load-bearing
  note on the `/srv/nfs/k8s` path and the mount guard.
- `proxmox/README.md`, `ansible/README.md` — where the NFS server lives.

## Verification

- `terraform fmt -check && terraform validate` in `shared/` and `dev/`.
- `ansible-lint` on the role and playbook; `--syntax-check` with
  `-i inventories/shared`.
- `pre-commit run --all-files`; `scripts/check-manifests.sh`.
- The plan gates above.
- On `nfs-01` after migration:
  - `lsblk` and `findmnt` show `scsi1` at `/srv/nfs/k8s` and `scsi2` at
    `/srv/nfs/prod`.
  - `showmount -e` lists exactly `/srv/nfs/k8s` for the three dev node IPs
    and no prod line.
  - `sudo reboot`; afterwards both mounts and the export return.
- Cluster: `kubectl get pvc -A` all `Bound`; gitea UI loads, a `docker push`
  to Harbor succeeds, postgres answers a query, Grafana shows data.
- A throwaway PVC's file appears on the `scsi1` filesystem, then the PVC is
  deleted.

## Landing

Branch `nfs-shared-server`, one PR. The PR body lists the operator steps in
order — pre-flight, dev apply, shared apply, migration, role run — all
manual, none gated on the merge. The only manifest change is the inert prod
provisioner. The repository owner merges.

## Out of scope

- Moving `vault-01` into `shared/`.
- A prod VLAN or subnet.
- Backups of the data disks.
- Renaming the dev share path.
