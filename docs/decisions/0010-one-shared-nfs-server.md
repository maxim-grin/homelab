# 0010. One shared NFS server, a disk per share, mounted by label

**Status:** Accepted (2026-09-22)

## Context

`nfs-01` lived in the `dev` Terraform root, exporting one share,
`/srv/nfs/k8s`, from its 20G OS disk to all of `10.0.0.0/24`. A future
prod cluster's storage would then depend on a machine dev's
`terraform apply` could change or destroy, nothing separated the
environments' data, and a full share could take the VM's own OS disk down
with it.

## Decision

Move `nfs-01` into a new `terraform/environments/shared` root with its own
state and tfvars, adopted in place at the same vmid (103) and IP
(`10.0.0.131`). Give it one virtual disk per share — `scsi1` for
`nfs-dev`, `scsi2` for `nfs-prod`, later `scsi3` for backups — each
exported only to its own cluster's exact node IPs, mounted by label. The
`nfs_server` role refuses to mount over a non-empty directory and the
service will not start until all disks are mounted. The dev share's path
stays `/srv/nfs/k8s`: existing PVs have it baked in and the field is
immutable.

## Consequences

dev and prod now have independent free-space pools and client lists, and
a `terraform destroy` of dev cannot touch prod's disk. `nfs-prod` has no
export line until prod has nodes — an export with no client list is
exported to everyone. The VM itself was adopted in place, same vmid and
IP, but its data still had to move: auto-sync was disabled on the apps
using it, their stateful workloads and the provisioner scaled to 0, the
old export rsynced onto the new `nfs-dev` disk, `nfs-server` restarted
onto it, and everything scaled back up. Only the PV paths and the
server's IP stayed the same — the migration itself was not a no-op.

## Related

`docs/superpowers/specs/2026-09-22-nfs-shared-server-design.md`;
[#31](https://github.com/maxim-grin/homelab/pull/31),
[#37](https://github.com/maxim-grin/homelab/pull/37); CLAUDE.md "nfs-dev"
and "`nfs-dev`'s share path" bullets.

Update 2026-10-03: `nfs-prod` is now exported to `talos-w1` and
`talos-w2` only; the decision is unchanged.
