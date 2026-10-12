# SSD rebuild drill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the prep PR that makes the SSD swap safe (an off-box checklist, Vault wording), then run the drill from `docs/rebuild.md` and fold every gap it finds back into the docs.

**Architecture:** Tasks 1-2 are the prep PR on branch `ssd-rebuild-drill` (draft #138, which already holds the spec). Task 3 is the operator gate and the drill itself, run by the owner with this session walking them through it one step at a time. Task 4 is the post-drill docs PR.

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

- The off-box checklist must never print a secret: digests and presence only.
- `check-runbooks.sh` fails if a new runbook entry's anchor is missing from the README index.
- The Vault wording must not leave a path that says "restore a snapshot" after a disk loss; the old unseal key is useless after a fresh init.
- `dev_register.yaml` writes `kv-prod/argocd/clusters/dev`, which is not in `vault_kv`; the rebuild order must say to re-run it.

---

### Task 1: Off-box checklist runbook

**Files:**
- Modify: `docs/runbooks/backups-and-recovery.md` (new `## Before an SSD swap` with one entry, `### Check the off-box set`; it sits after "Flip jobs.mgryn.cc to prod" and before "Rebuild pointers")
- Modify: `docs/runbooks/README.md` (index row for the entry)

**Interfaces:**
- Consumes: the entries "Dump jobboard's database" and "What has no backup" (link, do not restate).
- Produces: the gate Task 3 step 1 runs.

The entry's content, as decisions:
- When: before a swap or any rebuild that loses prod's volumes.
- Items checked, each with a command whose output is a word or a digest, never a secret: a fresh prod dump exists on the workstation with its sha256 and a second copy elsewhere; the `rebuild.md` section 4 files exist (the three tfvars, `prod` state and `backend.tf`, the SSH key, `~/.homelab-ca/`); every prod app is Synced and Healthy; the Vault unseal key and root token are in the password manager (owner confirms by hand, not by command); the ansible-vault password opens `secret.yaml` (`ansible-vault view ansible/secret.yaml >/dev/null; echo rc=$?`).
- States that the old unseal key and root token are useless after the swap and the new pair is recorded straight after init.
- Expect/if-not lines in the style of neighbouring entries.

- [ ] **Step 1: Implement** as above.
- [ ] **Step 2: Check.** `scripts/check-runbooks.sh` passes; the README row's link resolves; no command prints a secret.
- [ ] **Step 3: Commit** `docs: add the off-box checklist for an ssd swap`.

---

### Task 2: Vault is rebuilt, not restored

**Files:**
- Modify: `docs/rebuild.md` (the "What is destroyed and not backed up" Vault row; the section 4 "Vault root token" row; the heading note above "Restoring Vault from a snapshot" so it reads as the bad-upgrade path; step 7's tail points at a fresh init plus seed, then `dev_register` for `kv-prod/argocd/clusters/dev`)
- Modify: `docs/runbooks/backups-and-recovery.md` ("What has no backup": the Vault key row no longer says "no snapshot can be restored" as the only consequence; it says a fresh init needs no old key)
- Modify: `CLAUDE.md` (the Vault bullet, one sentence: a lost disk is a fresh init plus the seed, not a snapshot restore)

**Interfaces:**
- Consumes: `playbooks-and-terraform.md#seed` and the `dev_register` entry (link, do not restate).
- Produces: wording the drill follows in Task 3.

- [ ] **Step 1: Implement** as above; change no command, only the framing and links.
- [ ] **Step 2: Check.** `scripts/check-runbooks.sh` and `pre-commit run --all-files` pass; `grep -n "from a snapshot" docs/rebuild.md` leaves only the bad-upgrade wording.
- [ ] **Step 3: Commit** `docs: rebuild vault from the seed, not a snapshot`.

After Tasks 1-2: push, run the final whole-branch review, `gh pr ready 138`, and hand the PR to the owner. The merge does not rebuild anything; it only makes the gate passable.

---

### Task 3: Gate and drill (operator only, not delegated)

This session walks the owner through it one command at a time; nothing here runs on this box.

- [ ] **Step 1: Gate.** Run [Check the off-box set](../../runbooks/backups-and-recovery.md#check-the-off-box-set); expect every item present. The old SSD is labelled and the new one is the right size.
- [ ] **Step 2: Hold.** Final fresh prod dump taken last, with the apps quiet; record the digest and the `users`/`jobs`/`companies` counts.
- [ ] **Step 3: Swap and rebuild** `rebuild.md` "Rebuild order" top to bottom, steps as written. Proxmox memory per node is read before and after the prod apps sync. On a failure or a wrong doc line, note it in the ledger and continue; fix on a branch afterwards.
- [ ] **Step 4: Restore** the prod dump with [Restore the dump into prod-jobboard](../../runbooks/backups-and-recovery.md#restore-the-dump-into-prod-jobboard); counts must match step 2.
- [ ] **Step 5: Pass criteria** 1-6 from the spec, each shown with its output.
- [ ] **Step 6: Record** the new Vault unseal key and root token; keep the old SSD and the dump copies until Task 4 merges.

---

### Task 4: Post-drill docs PR

**Files:**
- Modify: `docs/rebuild.md`, the runbooks and `docs/decisions/` as the drill's ledger dictates; an ADR only if a decision changed

- [ ] **Step 1: Implement** one fix per gap, each citing the step that failed.
- [ ] **Step 2: Check.** `scripts/check-runbooks.sh`, `pre-commit run --all-files`.
- [ ] **Step 3: Commit** `docs: fold the ssd drill findings into rebuild`.
- [ ] **Step 4: After merge** the owner may delete the old dump copies and put the old SSD to a use of their choosing.
