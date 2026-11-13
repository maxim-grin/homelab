# 0033. The shortener keeps SQLite on the NFS StorageClasses

**Status:** Accepted (2026-11-13)

## Context

The url shortener (`ghcr.io/maxim-grin/multi-short-url`) stores its links in
one SQLite file. SQLite relies on file locking, and NFS locking is a known
weak spot for it. The links must survive a pod restart. The repo's
StorageClasses are `nfs-dev` and `nfs-prod`
([0003](0003-nfs-default-storageclass.md)); it defines no node-local class.

## Decision

**The file lives on a PVC of `nfs-dev` (dev) and `nfs-prod` (prod), mounted at
`/data`, so a pod restart does not lose the links.** One replica with the `Recreate` strategy, so two pods never open
the file at once. The pod runs as uid and gid 10001 with `fsGroup` 10001.

Rejected:

- **A node-local volume (hostPath or local-path)**: survives a pod restart
  but not losing the node, and needs a StorageClass this repo does not define.
- **Postgres, as jobboard uses**: proper locking, but a second store to run
  and a different app store.
- **`emptyDir`**: links would vanish on every pod restart.

## Consequences

- Not tested yet. If a pod logs `database is locked` or creates return 503,
  NFS locking is the first suspect.
- NFS often ignores `fsGroup`. If the pod exits with `shortener: unable to
  open database file`, the volume is not writable by uid 10001 and the fix
  is on `nfs-01` or the provisioner, not in the app.
- Like every NFS-backed app, it is down when `nfs-01` is (0003).
- Deleting the PVC deletes every link on dev (`nfs-dev` removes the data).
  On prod, `nfs-prod` retains it (`reclaimPolicy: Retain`, `archiveOnDelete`).
- Only Vault has snapshots: losing the SSD loses the links
  ([backups-and-recovery](../runbooks/backups-and-recovery.md)).

## Related

Builds on [0003](0003-nfs-default-storageclass.md).
