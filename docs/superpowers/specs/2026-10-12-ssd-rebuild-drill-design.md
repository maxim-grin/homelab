# SSD rebuild drill

Status: draft for review. Follows jobboard in prod
([spec](2026-10-11-jobboard-prod-design.md), ADR 0028) and the roadmap's
SSD plan ([roadmap](2026-09-26-homelab-roadmap-design.md)).

## Goal

Prove that `docs/rebuild.md` brings the whole homelab back from a bare
Proxmox install on a new SSD, and fix what it gets wrong. The first true
drill: until now every rebuild step ran against a live host.

## Decisions

- **Old SSD stays intact.** Swap the new one in; the old one goes on the
  shelf untouched. Before prod is rebuilt, swapping it back is the
  rollback. After that the drill rolls forward.
- **One sitting.** A prep PR lands first. Then one planned outage runs
  `rebuild.md` "Rebuild order" top to bottom. No phasing over days: the
  old SSD could not be the rollback once phase 1 started.
- **Vault is rebuilt, not restored.** `vault operator init` plus the seed
  play rebuilds `kv-dev/` and `kv-prod/` from `ansible/secret.yaml`'s
  `vault_kv`. `kv-prod/argocd/clusters/dev` is not in `vault_kv`; re-run
  `dev_register.yaml`. A fresh init gives a new unseal key and root token,
  which go to the password manager before anything depends on them; the
  old pair is useless afterwards. The raft-snapshot restore stays
  documented as the bad-upgrade path, no longer the disk-failure path.
- **Grafana state is not preserved.** The repo is the source of truth:
  a dashboard that exists only in the UI is gone with the SSD, as the old
  dev cluster's were. The chart's built-in dashboards come back from git.
  Anything worth keeping later goes in git as a ConfigMap labelled
  `grafana_dashboard: "1"` (the chart's sidecar loads it); nothing is
  built for that now.
- **The only data that must leave the box is prod's jobboard database.**
  Prometheus metrics are not worth keeping, and everything else is
  reproducible from git, `secret.yaml` and Vault's seed.

## Before the swap (the gate)

All true, or the drill does not start:

- A fresh prod jobboard dump is on the workstation with its sha256
  recorded, and a second copy elsewhere
  ([backups-and-recovery.md](../../runbooks/backups-and-recovery.md)).
- The workstation files from `rebuild.md` section 4 exist: tfvars,
  `prod` Terraform state and `backend.tf`, SSH key, ansible-vault
  password, `~/.homelab-ca/`.
- The old SSD is labelled and set aside; the new one is the right size.

## During

The owner runs each `rebuild.md` step as written and pastes the output.
When a step fails or the doc is wrong, the fix goes on a branch and the
run continues; no commands the doc lacks are improvised.

## Pass criteria

1. `scripts/verify-dev.sh` passes with the Vault checks run for real
   (install the `vault` CLI first).
2. Every prod and dev app is Synced and Healthy.
3. `jobs.mgryn.cc` serves the restored data; row counts match the dump's.
4. Grafana answers with the chart's built-in dashboards.
5. Pi-hole, Traefik and Gatus answer.
6. The fresh Vault keys are recorded.

## Risks

- The prod Terraform state (Talos PKI) and the ansible-vault password
  exist only on the workstation. A fresh cluster also needs `prod.tfvars`
  and `backend.tf` from there.
- Prod worker `talos-prod-w2` already sits at 91% memory (limits 99%). A
  rebuild reinstalls every app at once; record Proxmox memory per node.
- New VMs get new MACs: router leases and the extender may need
  attention.
- A rebuild re-requests every certificate. Use `letsencrypt-staging` if
  a failure repeats (5 failed validations per hostname per hour).

## Deliverables

1. **Prep PR** (before the swap): an off-box checklist runbook entry, the fresh-init-first Vault wording in
   `rebuild.md`, this spec and its plan.
2. **The drill:** operator only, no PR.
3. **Post-drill PR:** every gap found folded into `rebuild.md` and the
   runbooks, an ADR if a decision changed. The old dump copies are
   deleted only after this.

## Out of scope

Scheduled or off-site jobboard backups, the prod cp1 resize, the
`claude_code` pool drift, and a dry run on spare hardware.
