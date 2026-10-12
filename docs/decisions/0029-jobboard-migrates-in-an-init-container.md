# 0029. jobboard migrates its database in an init container

**Status:** Accepted (2026-10-12)

## Context

jobboard 0.3.x no longer creates or upgrades its schema on start. It
compares the database with its head revision and exits with `database is
at none, expected 0001; run jobboard migrate`. Bumping prod and dev from
0.2.7 to 0.3.2 (#141) crash-looped both until `jobboard migrate` was run
by hand, because nothing here ran it. `migrate` adopts a legacy schema
(all tables, no `alembic_version`) after a drift check, upgrades a
versioned one, takes an advisory lock, and exits 0 printing
`database at <revision>` when nothing is pending.

## Decision

**The Deployment runs `jobboard migrate` in an init container.**
`argocd/apps/jobboard/base/app-deployment.yaml` gains a `migrate`
initContainer on the same image and `DATABASE_URL` as the app. The
overlay's `newTag` moves both, so a version bump migrates the database
as part of the rollout and needs no operator step.

Rejected:

- **An Argo PreSync Job**: a second object to order against the Secret
  and Postgres, and it runs before the new pod exists, so a failing
  migration still leaves the old code running against a half-new schema.
- **Migrating in the app's entrypoint**: what 0.3.x deliberately stopped
  doing; a crash in the app would hide a migration failure.
- **Migrating by hand per bump**: what #141 needed, and what this
  replaces.

## Consequences

- The Deployment is `Recreate` with one replica, so no other app pod runs
  during a migration. A failed migration is an outage until fixed, the
  same as the crash loop it replaces, but the cause is in
  `logs -c migrate` and the pod shows `Init:Error`.
- The migration runs with the new code's schema, ahead of any rollback:
  rolling back to a tag below the database's revision fails with
  `database is ahead of this build`. Dump first
  ([runbook](../runbooks/backups-and-recovery.md#dump-jobboards-database)).
- Every pod start runs `migrate`; at head it is a no-op that exits 0.

## Related

Records [0007](0007-pin-image-tags-not-latest.md),
[0028](0028-jobboard-in-prod.md); runbook
[Read a failed jobboard migration](../runbooks/checks.md#read-a-failed-jobboard-migration).
