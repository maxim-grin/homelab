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
exported to everyone. The migration was in-place (same vmid), so nothing
on the cluster side changed; only the prod provisioner manifest, which
nothing syncs yet.

## Related

`docs/superpowers/specs/2026-09-22-nfs-shared-server-design.md`;
[#31](https://github.com/maxim-grin/homelab/pull/31),
[#37](https://github.com/maxim-grin/homelab/pull/37); CLAUDE.md "nfs-dev"
and "`nfs-dev`'s share path" bullets.
