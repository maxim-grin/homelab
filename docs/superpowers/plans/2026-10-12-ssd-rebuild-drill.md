# SSD rebuild drill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the prep PR that makes the SSD swap safe (dashboards in git, an off-box checklist, Vault wording), then run the drill from `docs/rebuild.md` and fold every gap it finds back into the docs.

**Architecture:** Tasks 1-3 are the prep PR on branch `ssd-rebuild-drill` (draft #138, which already holds the spec). Task 4 is the operator gate and the drill itself, run by the owner with this session walking them through it one step at a time. Task 5 is the post-drill docs PR.

**Tech Stack:** kustomize (`configMapGenerator`), the kube-prometheus-stack Grafana sidecar, the runbooks, `docs/rebuild.md`.

**Spec:** `docs/superpowers/specs/2026-10-12-ssd-rebuild-drill-design.md`

## Global Constraints

- Branch `ssd-rebuild-drill`; PR only, never merge or push to `main`; the owner merges.
- Commits: Conventional, subject at most 50 characters, imperative, lowercase, body wrapped at 72, no `Co-Authored-By`, no generated-with footer, never `--no-verify`.
- Plans record decisions, not finished code. Exact names, paths and values stay verbatim.
- A new operator step or flag updates its runbook in the same PR and is linked from `docs/runbooks/README.md`; no command is restated in `rebuild.md` (ADR 0025).
- No secret value appears in any committed file, under any name.
- `scripts/check-manifests.sh`, `scripts/check-appsets.sh`, `scripts/check-runbooks.sh` and `pre-commit run --all-files` pass before each commit.
- Vault is rebuilt, not restored: `vault operator init` plus the seed play (spec, "Decisions"). The raft-snapshot restore stays documented as the bad-upgrade path.
- Operator steps run on the owner's Mac; this box has no kubeconfig, tfvars or Vault access.

## Review Focus

- A dashboard JSON that exceeds the 1 MiB ConfigMap limit (or the 256 KiB annotation limit) renders but fails on apply: the app needs `serverSideApply: true`, and an oversize file must be called out, not silently dropped.
- A dashboard whose JSON carries a fixed `id` or a datasource UID that the rebuilt Grafana does not have: it loads empty. The brief tells the implementer to check each exported file's datasource references against the provisioned Prometheus datasource.
- Two dashboards with the same `uid` overwrite each other silently.
- The off-box checklist must never print a secret: digests and presence only.
- `check-runbooks.sh` fails if a new runbook entry's anchor is missing from the README index.

---

### Task 1: Prod dashboards app

Blocked on the owner handing over the exported dashboard JSON (Grafana, Share, Export, "Export for sharing externally" off). The implementer starts only once those files exist in the scratchpad or are named by path.

**Files:**
- Create: `argocd/apps/dashboards/config.yaml` (one `env: prod` entry, namespace `monitoring`, `createNamespace: false`, `serverSideApply: true`; header comment in the style of `argocd/apps/alerts/config.yaml`, ordering note: after `monitoring-secrets` and `kube-prometheus-stack`)
- Create: `argocd/apps/dashboards/prod/kustomization.yaml` (one `configMapGenerator` entry per dashboard, label `grafana_dashboard: "1"`, `disableNameSuffixHash: true`, no `namespace:` transformer, each ConfigMap in `monitoring`)
- Create: `argocd/apps/dashboards/prod/<name>.json` (the owner's exports, unmodified except where the brief says)
- Modify: `README.md` (Apps row: name the dashboards app), `docs/runbooks/checks.md` (one entry: confirm the dashboards loaded in Grafana)

**Interfaces:**
- Consumes: the kube-prometheus-stack Grafana sidecar (`argocd/apps/kube-prometheus-stack/prod/values.yaml`, `grafana.sidecar`), which loads ConfigMaps by label from its own namespace.
- Produces: the generated app `prod-dashboards`, which Task 4's pass criterion 4 checks.

- [ ] **Step 1: Implement** as above. Check every exported file for a fixed `id` (set to `null`), a `uid` unique across the set, and datasource references that resolve to the chart's Prometheus datasource; report any that do not rather than editing silently.
- [ ] **Step 2: Check.** `kustomize build argocd/apps/dashboards/prod` renders one ConfigMap per file carrying the label; `scripts/check-manifests.sh` and `scripts/check-appsets.sh` pass and the set expands to include `prod-dashboards` pointing at `argocd/apps/dashboards/prod`; no rendered ConfigMap exceeds 256 KiB.
- [ ] **Step 3: Commit** `feat: provision grafana dashboards from git`.

---

### Task 2: Off-box checklist runbook

**Files:**
- Modify: `docs/runbooks/backups-and-recovery.md` (new `## Before an SSD swap` with one entry, `### Check the off-box set`; it sits after "Flip jobs.mgryn.cc to prod" and before "Rebuild pointers")
- Modify: `docs/runbooks/README.md` (index row for the entry)

**Interfaces:**
- Consumes: the entries "Dump jobboard's database" and "What has no backup" (link, do not restate).
- Produces: the gate Task 4 step 1 runs.

The entry's content, as decisions:
- When: before a swap or any rebuild that loses prod's volumes.
- Items checked, each with a command whose output is a word or a digest, never a secret: a fresh prod dump exists on the workstation with its sha256 and a second copy elsewhere; the `rebuild.md` section 4 files exist (the three tfvars, `prod` state and `backend.tf`, the SSH key, `~/.homelab-ca/`); `prod-dashboards` is Synced and Healthy; the Vault unseal key and root token are in the password manager (owner confirms by hand, not by command); the ansible-vault password opens `secret.yaml` (`ansible-vault view ansible/secret.yaml >/dev/null; echo rc=$?`).
- States that the old unseal key and root token are useless after the swap and the new pair is recorded straight after init.
- Expect/if-not lines in the style of neighbouring entries.

- [ ] **Step 1: Implement** as above.
- [ ] **Step 2: Check.** `scripts/check-runbooks.sh` passes; the README row's link resolves; no command prints a secret.
- [ ] **Step 3: Commit** `docs: add the off-box checklist for an ssd swap`.

---

### Task 3: Vault is rebuilt, not restored

**Files:**
- Modify: `docs/rebuild.md` (the "What is destroyed and not backed up" Vault row; the section 4 "Vault root token" row; the heading note above "Restoring Vault from a snapshot" so it reads as the bad-upgrade path; step 7's tail points at a fresh init plus seed, then `dev_register` for `kv-prod/argocd/clusters/dev`)
- Modify: `docs/runbooks/backups-and-recovery.md` ("What has no backup": the Vault key row no longer says "no snapshot can be restored" as the only consequence; it says a fresh init needs no old key)
- Modify: `CLAUDE.md` (the Vault bullet, one sentence: a lost disk is a fresh init plus the seed, not a snapshot restore)

**Interfaces:**
- Consumes: `playbooks-and-terraform.md#seed` and the `dev_register` entry (link, do not restate).
- Produces: wording the drill follows in Task 4.

- [ ] **Step 1: Implement** as above; change no command, only the framing and links.
- [ ] **Step 2: Check.** `scripts/check-runbooks.sh` and `pre-commit run --all-files` pass; `grep -n "from a snapshot" docs/rebuild.md` leaves only the bad-upgrade wording.
- [ ] **Step 3: Commit** `docs: rebuild vault from the seed, not a snapshot`.

After Tasks 1-3: push, run the final whole-branch review, `gh pr ready 138`, and hand the PR to the owner. The merge does not rebuild anything; it only makes the gate passable.

---

### Task 4: Gate and drill (operator only, not delegated)

This session walks the owner through it one command at a time; nothing here runs on this box.

- [ ] **Step 1: Gate.** Run [Check the off-box set](../../runbooks/backups-and-recovery.md#check-the-off-box-set); expect every item present. The old SSD is labelled and the new one is the right size.
- [ ] **Step 2: Hold.** Final fresh prod dump taken last, with the apps quiet; record the digest and the `users`/`jobs`/`companies` counts.
- [ ] **Step 3: Swap and rebuild** `rebuild.md` "Rebuild order" top to bottom, steps as written. Proxmox memory per node is read before and after the prod apps sync. On a failure or a wrong doc line, note it in the ledger and continue; fix on a branch afterwards.
- [ ] **Step 4: Restore** the prod dump with [Restore the dump into prod-jobboard](../../runbooks/backups-and-recovery.md#restore-the-dump-into-prod-jobboard); counts must match step 2.
- [ ] **Step 5: Pass criteria** 1-6 from the spec, each shown with its output.
- [ ] **Step 6: Record** the new Vault unseal key and root token; keep the old SSD and the dump copies until Task 5 merges.

---

### Task 5: Post-drill docs PR

**Files:**
- Modify: `docs/rebuild.md`, the runbooks and `docs/decisions/` as the drill's ledger dictates; an ADR only if a decision changed

- [ ] **Step 1: Implement** one fix per gap, each citing the step that failed.
- [ ] **Step 2: Check.** `scripts/check-runbooks.sh`, `pre-commit run --all-files`.
- [ ] **Step 3: Commit** `docs: fold the ssd drill findings into rebuild`.
- [ ] **Step 4: After merge** the owner may delete the old dump copies and put the old SSD to a use of their choosing.
