# jobboard in prod Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking. Per CLAUDE.md, this plan
> records decisions, files, order and checks, not finished code: the
> implementer writes the code. Exact values stay verbatim.

**Goal:** jobboard runs on the prod hub with the 2026-10-11 dump
restored and `jobs.mgryn.cc` pointing at it; dev stays as staging.

**Architecture:** A `prod` overlay of the existing `argocd/apps/jobboard`
app, generated as `prod-jobboard` by the hub's `apps` set. `base/` loses
its hard-coded storage class; each overlay names its own. Data comes from
the dump through `tools/db-backup.sh restore` (job-board repo), which runs
`pg_restore --clean --if-exists --no-owner --single-transaction`, so it
is safe over a database the app already migrated.

**Tech Stack:** kustomize, ArgoCD ApplicationSet (ADR 0026), AVP
(`kv-prod`), cert-manager `letsencrypt-prod`, `nfs-prod`, Cloudflare
DNS-only records (manual).

**Spec:** [2026-10-11-jobboard-prod-design.md](../specs/2026-10-11-jobboard-prod-design.md)

## Global Constraints

- Merge is the deploy; the agent's work ends at an open PR. The owner
  runs every operator step and pastes output; give one step at a time.
- No secret value in git: AVP placeholders `<path:kv-prod/data/...#FIELD>`
  only. `JOBBOARD_SECRET`, `POSTGRES_PASSWORD`, `DATABASE_URL` are new
  values the owner seeds into `kv-prod/jobboard/db`; the ghcr credential
  is copied to `kv-prod/jobboard/ghcr` field `dockerconfigjson`.
- Prod tag pin: `newTag: "0.2.7"`, the tag the dump's schema came from
  (dev is on `"0.2.7"` today). Never lower than the dump's schema.
- Prod limits: app `512Mi`, Postgres `512Mi`; requests stay `256Mi`/`100m`.
  Storage `5Gi` on `nfs-prod`. Ingress class `nginx`, issuer
  `letsencrypt-prod`, host `jobs.mgryn.cc`, TLS secret `jobboard-tls`.
- Dump: 76,425,607 bytes, sha256
  `d4922fc872ebe7c808f861eb53802215234b36f034a036eb5b5749f610f6903b`;
  verify before use on the machine that runs the restore.
- Prod workers have about 3.3 GiB allocatable; one reads 99% of memory
  limits already; prod cp1 sits at 80% of 4 GiB. Read Proxmox memory per
  worker before and after the first sync.
- Commits: Conventional, subject ≤ 50 chars lowercase imperative, body
  wrapped at 72, no `Co-Authored-By`, no generated-with footer.
- Docs and the ADR land in the same PR; runbook commands live in
  `docs/runbooks/` (ADR 0025).

## Sequencing ruling

The spec renames dev's host to `dev-jobs.mgryn.cc`. Merging that rename
before the DNS flip would leave `jobs.mgryn.cc` answering 404 on dev
until the flip. So two PRs: this PR (#130) adds prod and every doc, and
leaves dev's host alone; a follow-up PR renames dev's host after the flip
(Task 5). Both names are served by distinct clusters, so they never
conflict in between.

## Review Focus

- Dev's rendered manifests are byte-identical after `base/` loses
  `storageClassName` (the claim template is immutable; any diff means
  dev's StatefulSet would be rejected).
- Prod's Postgres PVC binds on `nfs-prod`; a Pending PVC reads as an
  app fault. `prod-nfs-provisioner` must be Healthy first.
- A missing `kv-prod/jobboard/*` seed shows as `ComparisonError` on
  `prod-jobboard`, not as a sealed-Vault tell; a missing ghcr field gives
  `ImagePullBackOff` with `denied`.
- A dump older than the pinned tag's schema is fine; newer is not.
  Row counts, not only exit codes, prove the restore.
- Two clusters hold certificates for `jobs.mgryn.cc` during the
  window; DNS-01 does not care, but the cert must be `Ready` on prod
  before the flip.
- cp1's memory after `prod-jobboard` appears (the controller caches one
  more app).

---

### Task 1: Prod overlay, environment-free base

**Files:**
- Modify: `argocd/apps/jobboard/base/postgres-statefulset.yaml` (drop the
  `storageClassName: nfs-dev` line only)
- Modify: `argocd/apps/jobboard/dev/kustomization.yaml` (patch the claim
  template's `storageClassName: nfs-dev` back in)
- Create: `argocd/apps/jobboard/prod/{kustomization,secret,ghcr-secret,ingress}.yaml`

**Interfaces:**
- Consumes: `argocd/apps/jobboard/base` (Deployment `jobboard`, Service,
  StatefulSet `postgres`), cluster-scoped `letsencrypt-prod`.
- Produces: kustomize directory `argocd/apps/jobboard/prod` the hub
  deploys as `prod-jobboard` (Task 2).

- [ ] **Step 1: Record dev's render.** `kustomize build argocd/apps/jobboard/dev > "$SCRATCH/dev-before.yaml"` (scratchpad, not the repo).
- [ ] **Step 2: Edit base and dev** as above. The dev patch must put the
  field in the StatefulSet's `volumeClaimTemplates[0].spec`.
- [ ] **Step 3: Prove dev unchanged.** Build dev again and
  `diff "$SCRATCH/dev-before.yaml" <(kustomize build argocd/apps/jobboard/dev)`.
  Expect: no output. Any diff is a stop.
- [ ] **Step 4: Write the prod overlay.** Mirror dev's kustomization:
  `namespace: jobboard`, resources `../base`, the three files; `images`
  pin; patches for both memory limits and `storageClassName: nfs-prod`.
  `secret.yaml` and `ghcr-secret.yaml` copy dev's shapes with `kv-prod`
  mounts (`kv-prod/data/jobboard/db`: `POSTGRES_PASSWORD`, `DATABASE_URL`,
  `JOBBOARD_SECRET`; `kv-prod/data/jobboard/ghcr#dockerconfigjson`).
  `ingress.yaml` copies dev's with `cert-manager.io/cluster-issuer:
  letsencrypt-prod`, host/TLS `jobs.mgryn.cc`, secret `jobboard-tls`.
  Keep comments to what differs from dev; do not copy dev's history.
- [ ] **Step 5: Check.** `kustomize build argocd/apps/jobboard/prod | grep -E 'storageClassName|memory:|image:|host:'`.
  Expect: `nfs-prod`, `512Mi` twice, `ghcr.io/maxim-grin/jobboard:0.2.7`,
  host `jobs.mgryn.cc`, and no `kv-dev` anywhere.
- [ ] **Step 6: Commit** `feat: add the prod jobboard overlay`.

### Task 2: Generate prod-jobboard from the hub

**Files:**
- Modify: `argocd/apps/jobboard/config.yaml` (add `- env: prod`,
  `namespace: jobboard`, `createNamespace: true`, `serverSideApply: true`;
  replace the "Dev only" sentence in its header comment)

- [ ] **Step 1: Edit** as above, matching how the other apps spell prod
  entries (see `argocd/apps/cert-manager-issuers/config.yaml`).
- [ ] **Step 2: Check.** `scripts/check-appsets.sh` and
  `scripts/check-manifests.sh`; expect both to pass and the expansion to
  list `prod-jobboard` → `argocd/apps/jobboard/prod`.
- [ ] **Step 3: Commit** `feat: generate prod-jobboard from the hub`.

### Task 3: Runbooks, ADR, docs

**Files:**
- Create: `docs/decisions/0028-jobboard-in-prod.md` (jobboard on the hub,
  dev as staging, restore from the dump, fresh `JOBBOARD_SECRET`;
  supersedes nothing; update `docs/decisions/README.md`)
- Modify: `docs/runbooks/checks.md`: entries "Check the prod jobboard
  seed" (read-only presence check of `kv-prod/jobboard/db` and `ghcr`
  without printing values, in the style of "Is KV seeded"), "Promote a
  jobboard tag to prod"
- Modify: `docs/runbooks/backups-and-recovery.md`: "Restore jobboard's
  database into prod" (hold, checksum, restore, row counts, release) and
  "Flip jobs.mgryn.cc to prod"; fold the rollback in
- Modify: `docs/runbooks/README.md` index rows, `docs/runbooks/access.md`
  (names table: `jobs.mgryn.cc` now prod workers; `dev-jobs.mgryn.cc`
  after Task 5), `README.md` table and diagram, `docs/rebuild.md`,
  `docs/operations.md`, `CLAUDE.md` (`jobs.mgryn.cc` statements)

- [ ] **Step 1: Write the runbook entries** with the exact commands from
  the Cutover section below; each ends with Expect/If not.
- [ ] **Step 2: Write the ADR and update the docs** listed.
- [ ] **Step 3: Check.** `scripts/check-runbooks.sh`; `pre-commit run
  --all-files`; expect pass.
- [ ] **Step 4: Commit** `docs: add jobboard in prod`.

### Task 4: Cutover (operator, after the PR merges)

Not an implementer task. The supervisor gives one step at a time, reads
the output, and stops on any mismatch. Gate before step 1: `prod-nfs-provisioner`
Healthy; Vault unsealed; the dump present with the checksum above.

- [ ] **Step 1: Seed `kv-prod/jobboard/db` and `kv-prod/jobboard/ghcr`**
  (owner). Check with the seed-check entry: fields present, none printed.
- [ ] **Step 2: Merge #130.** Expect `prod-jobboard` generated; Postgres
  PVC `Bound` on `nfs-prod`; read Proxmox memory of both workers and cp1.
- [ ] **Step 3: Hold `prod-jobboard`** and restore (entry from Task 3).
  Expect: `pg_restore` exit 0 and row counts equal to the dump's.
- [ ] **Step 4: Prove prod before DNS.** `curl` with
  `--resolve jobs.mgryn.cc:443:10.0.0.111` and `.112`; certificate
  `Ready`; log in with a restored account.
- [ ] **Step 5: Repoint `jobs.mgryn.cc`** to `.111`/`.112`. Check by
  name from the Mac. The `dev-jobs.mgryn.cc` record comes with the
  follow-up PR (Task 5).
- [ ] **Step 6: Keep the dump copies** until the SSD drill.

### Task 5: Dev as staging (follow-up PR, after the flip)

**Files:**
- Modify: `argocd/apps/jobboard/dev/ingress.yaml` (host and TLS hosts →
  `dev-jobs.mgryn.cc`; trim the history comment)
- Modify: `scripts/verify-dev.sh` and `scripts/tests/verify-dev.test.sh`
  (Host header and messages → `dev-jobs.mgryn.cc`; test fixtures follow)
- Modify: `docs/runbooks/access.md`, `README.md` mermaid edge label,
  `CLAUDE.md`, `docs/operations.md` where Task 3 left "after Task 5"

- [ ] **Step 1: Edit** as above on a new branch from merged `main`.
- [ ] **Step 2: Check.** `scripts/tests/verify-dev.test.sh` passes;
  `kustomize build argocd/apps/jobboard/dev | grep host:` shows only
  `dev-jobs.mgryn.cc`; `scripts/check-manifests.sh`.
- [ ] **Step 3: Commit** `feat: serve dev jobboard as dev-jobs`.
- [ ] **Step 4: After merge** run `scripts/verify-dev.sh 10.0.0.101`;
  expect `PASS` for the jobboard line.
