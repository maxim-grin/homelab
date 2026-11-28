# 0035. directive-copilot keeps Postgres and its dumps on nfs-prod

**Status:** Accepted (2026-11-26)

## Context

directive-copilot (question answering over regulator directives) needs
Postgres with pgvector, a local embedding model and a model gateway. Dev is
destroyed ([0034](0034-dev-destroyed-prod-grown.md)), prod's only
StorageClass is `nfs-prod`, and jobboard already runs Postgres on it. The NFS
`backups` share is not exported to the prod workers
([0010](0010-one-shared-nfs-server.md)).

## Decision

**The app runs on `prod`. Postgres is a one-replica StatefulSet on an
`nfs-prod` volume, and a nightly `pg_dump` CronJob writes to a second
`nfs-prod` volume, keeping the newest 14. No database operator.** Ollama
(embeddings) and LiteLLM (gateway, no database of its own) run beside it in
the `directive-copilot` namespace.

Rejected:

- **CloudNativePG or another operator**: failover and WAL archiving need a
  second replica or an object store, which one machine with one SSD cannot
  make independent.
- **A node-local volume**: ties the database to one worker and needs a
  StorageClass this repo does not define.
- **Dumps on the `backups` share**: it is exported to `vault-02` only, and
  opening it to the workers would let a pod read Vault's snapshots.

## Consequences

- Both volumes sit on the same disk on `nfs-01` (the prod share), on the same
  SSD as everything else. The dumps cover a bad change, deleted rows or a
  deleted database volume, **not a lost disk**; off-box copies are by hand
  ([Dump directive-copilot's database](../runbooks/backups-and-recovery.md#dump-directive-copilots-database)).
- A database that comes back empty is dumped like any other, so 14 runs
  later no good dump is left. Recovery starts by suspending the CronJob or
  copying the dumps out.
- Postgres on NFS follows jobboard; it is not tested for this load.
- Like every NFS-backed app, it is down when `nfs-01` is
  ([0003](0003-nfs-default-storageclass.md)).
- No alert rule is written for this backup. Only the monitoring chart's
  generic Job rules could notice a failed run, which is untested.
- The off-box set before an SSD swap still lists only jobboard's database;
  add this one once the app writes rows worth keeping.

## Related

Builds on [0010](0010-one-shared-nfs-server.md) and
[0034](0034-dev-destroyed-prod-grown.md).
