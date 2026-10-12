# 0028. jobboard runs on the prod hub; dev is its staging

**Status:** Accepted (2026-10-11)

## Context

jobboard is the owner's own web app, and it was the one app whose real
data lived on dev. Dev is now a spoke
([0027](0027-dev-is-a-spoke.md)) that gets replaced and rebuilt, and
dev's jobboard database is empty. Every app is a directory the
one ApplicationSet can deploy to any cluster
([0026](0026-uniform-apps.md)), and prod has the storage (`nfs-prod`) and
the secrets mount (`kv-prod`) to host it. The only copy of the data is
the 2026-10-11 dump.

## Decision

**jobboard runs on the prod hub as `prod-jobboard`.** The set generates
it from a `prod` entry in `argocd/apps/jobboard/config.yaml`; the overlay
is `argocd/apps/jobboard/prod`, with its own limits, `5Gi` on `nfs-prod`
and its secrets from `kv-prod/jobboard/`.

**Dev stays as staging.** A new tag runs on dev first. Prod pins its own
tag, and promotion is a pull request that bumps `newTag` in the prod
overlay; the merge is the deploy.

**The data is the 2026-10-11 dump.** It is restored into prod's empty
Postgres with `tools/db-backup.sh restore`, with `prod-jobboard` held
still. Prod never pins a tag below the dump's schema.

**A fresh `JOBBOARD_SECRET` in prod.** It only signs the login cookie;
password hashes live in the database, so users log in as before and
only existing sessions end.

**DNS moves last.** `prod-jobboard` is proven with `curl --resolve`
against both workers first, then `jobs.mgryn.cc` is repointed from the dev
node to the prod workers. Rolling back is pointing the record back.

**The dev rename follows in a second pull request.** Dev's host becomes
`dev-jobs.mgryn.cc` only after the flip; renaming it earlier would leave
`jobs.mgryn.cc` answering 404 on dev until the flip.

Rejected:

- **Keep jobboard on dev**: its volumes are the ones a dev rebuild
  loses, and the data would stay hostage to that cluster.
- **Copy the old `JOBBOARD_SECRET`**: it would have to be read out of
  dev's Vault path for no gain.

## Consequences

- Order: seed `kv-prod/jobboard/db` and `/ghcr` first (from
  `secret.yaml`'s `kv-prod` block), then merge; otherwise `prod-jobboard`
  sits in `ComparisonError`.
- Prod workers have about 3.3 GiB allocatable, one is near its memory
  limits and `cp1` sits at 80% of 4 GiB, so the first sync is bracketed by
  memory reads of all three.
- jobboard's database exists once, on `nfs-prod`, on the same SSD as
  everything else. The dump copies are kept until the SSD drill.
- A sealed Vault leaves `prod-jobboard` `Unknown` like any AVP app.
- The two names are served by distinct clusters, so the order of the
  flip and the dev rename never conflicts.

## Related

`docs/superpowers/specs/2026-10-11-jobboard-prod-design.md`; records
[0026](0026-uniform-apps.md),
[0027](0027-dev-is-a-spoke.md).
