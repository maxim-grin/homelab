# jobboard in prod (sub-project 5)

Status: draft for review. Follows the dev-spoke work
([spec](2026-10-05-dev-spoke-design.md), ADR 0027) and the roadmap's
sub-project 5 ([roadmap](2026-09-26-homelab-roadmap-design.md)).

## Goal

jobboard runs on the Talos prod hub with the data from the 2026-10-11
dump, `jobs.mgryn.cc` points at it, and dev keeps running jobboard as
staging on its own name. The SSD rebuild drill follows this.

## Decisions

- **Dev is staging.** Dev tracks the newest tag; prod is pinned and
  bumped by a PR after the same tag has run on dev. Rejected: removing
  jobboard from dev (no pre-prod slot) and dev following prod (no
  promotion).
- **Dev's name is `dev-jobs.mgryn.cc`**, a new DNS-only Cloudflare record
  to a dev node, same cert-manager DNS-01 path as today. `jobs.mgryn.cc`
  moves to prod.
- **The existing dump is the data.** The replaced dev cluster's jobboard
  database is empty, so there is no live dev data to freeze or re-dump.
  The dump (76,425,607 bytes, sha256
  `21179356ec9e2da483b0590b8b9a1b42c5ca337fdf7b7ea10e5b2db2420ac3d2`) has
  two verified copies on the owner's machines. Rows written to the new,
  empty dev jobboard since 2026-10-11 are not carried over.
- **Prod gets a fresh `JOBBOARD_SECRET`.** It only signs the login cookie
  (job-board README); password hashes live in `users.password_hash`, so
  the restored accounts still log in. Existing sessions end.

## Design

1. **Layout.** `argocd/apps/jobboard/prod/` and an `env: prod` entry in
   `argocd/apps/jobboard/config.yaml`, so the `apps` set generates
   `prod-jobboard` (namespace `jobboard`, `createNamespace`,
   `serverSideApply: true` as for dev). `base/` stays environment-free:
   `base/postgres-statefulset.yaml` hard-codes `storageClassName:
   nfs-dev`, so each overlay patches it (dev `nfs-dev`, prod `nfs-prod`).
   Dev's `ingress.yaml` host becomes `dev-jobs.mgryn.cc` in a
   follow-up PR after the DNS flip: renaming it in the same merge would
   leave `jobs.mgryn.cc` answering 404 on dev until the flip.
2. **Prod overlay.** Its own `images.newTag` pin, independent of dev's.
   Memory limits 512Mi for the app and 512Mi for Postgres (dev keeps
   1Gi each); requests unchanged (256Mi each). A 76 MB database does not
   need more, and prod worker limits are already committed to 99% on one
   node.
3. **Secrets.** `kv-prod/jobboard/db` (`POSTGRES_PASSWORD`,
   `DATABASE_URL`, `JOBBOARD_SECRET`) and `kv-prod/jobboard/ghcr`
   (`dockerconfigjson`), referenced as AVP placeholders. The owner seeds
   them with new values (ghcr credential copied); a runbook entry checks
   them without printing. Nothing secret is committed.
4. **Names and certificates.** Prod's Ingress serves `jobs.mgryn.cc` with
   the `letsencrypt-prod` ClusterIssuer (prod already runs cert-manager,
   its issuers and ingress-nginx). Cloudflare records are manual and
   DNS-only: `jobs.mgryn.cc` repointed from dev `.101` to the prod
   workers `.111`/`.112`; `dev-jobs.mgryn.cc` added for dev `.101`. Order:
   prod is brought up and proven by `Host:` header first; the DNS flip is
   last, so the rollback is flipping it back.
5. **Restore.** Hold `prod-jobboard` still (sync policy off, app scaled to
   0), restore the dump into prod's Postgres with
   `tools/db-backup.sh restore` against `$PROD_KC`, compare row counts
   with the dump's recorded counts, then re-enable sync and verify through
   the app. The existing "Hold dev-jobboard still" entry in
   `backups-and-recovery.md` is the template; the prod entry parallels it.
6. **Promotion.** A runbook entry: dev gets the new tag, runs, then a PR
   changes prod's `newTag`; the merge is the deploy. No Kargo or Image
   Updater (roadmap defers them).

## Verification and gates

- Proxmox memory of both prod workers before and after the first sync;
  prod cp1 stays near its 80% baseline (the controller caches one more
  app).
- `prod-jobboard` `Synced`/`Healthy`; `jobs.mgryn.cc` answers through
  the prod workers by `Host:` header before the DNS flip, and by name
  after; certificate `Ready`.
- Row counts after the restore equal the dump's; a login with a restored
  account works.
- Dev: `dev-jobboard` still `Synced`/`Healthy` under `dev-jobs.mgryn.cc`.
- `scripts/verify-dev.sh` is updated for the renamed dev host, and a
  `verify` check for prod jobboard is added alongside it or in its runbook
  entry.

## Rollback

Before the DNS flip: delete nothing; scale `prod-jobboard` to 0 and stop.
After it: flip `jobs.mgryn.cc` back to dev `.101` (dev's jobboard is empty
but running); prod's data stays. The dump copies are kept until the SSD
drill.

## Documentation

Same PR as the implementation: an ADR (jobboard in prod, dev as staging),
README table and diagram, `rebuild.md`, runbook entries (seed check,
restore into prod, DNS flip, promotion), `backups-and-recovery.md`.

## Out of scope

A scheduled jobboard backup (worthwhile, separate); off-site backup; the
prod cp1 resize; Kargo and Image Updater.
