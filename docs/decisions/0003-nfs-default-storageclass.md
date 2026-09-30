# 0003. NFS dynamic provisioning as the default StorageClass

**Status:** Accepted (2026-09-08)

## Context

Workloads need persistent storage, and the cluster has no cloud storage
API to provision it. A single NFS server VM, `nfs-01`, can back a
dynamic provisioner cheaply on one host.

## Decision

Make `nfs-dev` (backed by `nfs-subdir-external-provisioner` against
`nfs-01`) the default StorageClass, so every PVC without an explicit
class lands there automatically.

## Consequences

Every stateful app (Postgres for jobboard, Prometheus, Grafana) gets
storage with no per-app provisioning work. The cost is a single point of
failure: when the NFS provisioner is down, PVCs across every namespace sit
`Pending`, and unrelated apps read as broken. The share's path,
`/srv/nfs/k8s`, is baked into every existing PV's `nfs.path` and is
immutable once bound — `nfs-dev` also deletes a volume's data when its PVC
is deleted, so the path cannot simply be renamed later without a
migration.

## Related

CLAUDE.md, "`nfs-dev` is the default StorageClass" and "The `nfs-dev`
share's path"; README.md "What actually runs"; `ansible/roles/nfs_server`;
`argocd/apps/nfs_provisioner`.
