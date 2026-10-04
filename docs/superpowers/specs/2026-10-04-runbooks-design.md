# Operator Runbooks — Design

Replace the operator commands scattered across `rebuild.md`,
`ansible/README.md`, `operations.md`, specs, plans and pull request bodies
with one runbook set under `docs/runbooks/`, and keep it current with a drift
guard.

## Problem

The operator asks for the same commands again and again: how to run each
playbook with every parameter, how to check Vault, how to see what ArgoCD is
running. The commands exist, but they are spread over many files.

- `docs/rebuild.md` has 18 `ansible-playbook` invocations, laid out as a
  sequential rebuild; `ansible/README.md` has 10; `docs/operations.md` has one.
- Specs and plans hold more, and are history by design.
- Pull request operator checklists restate commands, sometimes with different
  flags than the doc they came from.
- There is no Makefile or `justfile`.
- Parameters are easy to get wrong: playbooks run from `ansible/`, the default
  inventory is `inventories/dev` so shared and prod hosts always need `-i`,
  secrets arrive as `-e @secret.yaml --ask-vault-pass`, and some playbooks need
  extra variables (`vault_token`, `vault_k8s_cluster_names`,
  `prod_kubeconfig`).

It is a finding problem, not a missing-content problem: most commands are
written down somewhere.

## Decisions

| Question | Decision |
| --- | --- |
| Shape | Runbooks only: documents, no wrapper tooling |
| Layout | `docs/runbooks/`: an index plus four area files |
| Areas | Playbooks and Terraform; health checks; access and URLs; backups and recovery |
| Source of truth | Runbooks own "how do I run or check X now"; `rebuild.md` owns "in what order for a rebuild" |
| Staying current | `scripts/check-runbooks.sh` in pre-commit and CI, plus a CLAUDE.md rule |
| De-duplication | A follow-up PR: `rebuild.md` and `ansible/README.md` link into the runbooks |
| Wrapper commands (`justfile`) | Not now; revisit if pasting stays tedious |
| When | Spec and plan now; implementation after the prod hub PRs (#86 to #89) merge |

## Design

### Layout

- `docs/runbooks/README.md`: the index, a table of "I want to… → runbook →
  anchor", and the conventions stated once so entries do not repeat them.
- `docs/runbooks/playbooks-and-terraform.md`
- `docs/runbooks/checks.md`
- `docs/runbooks/access.md`
- `docs/runbooks/backups-and-recovery.md`

Shared conventions, in the README:

- Playbooks run from `ansible/` with `-e @secret.yaml --ask-vault-pass`.
- `$DEV_KC` and `$PROD_KC` are the dev and prod kubeconfig paths (`rebuild.md`
  already uses `$PROD_KC`).
- Vault is reached with `VAULT_ADDR` and `read -rs VAULT_TOKEN`, so a token
  never lands in shell history, and is `unset` afterwards.
- A `<placeholder>` is always explained on the line above its command.

### Entry shape

Every task entry has the same parts: a verb title; when to run it; one
complete copy-paste block with every parameter; an "Expect:" line saying what
success prints; an "If not:" pointer. The pull request operator steps already
use this shape.

### Contents

**`playbooks-and-terraform.md`**

- Terraform per environment (`dev`, `shared`, `prod`): `plan` and `apply` with
  the right `-var-file`, reading the plan summary, the rule that an unintended
  `destroy` is a stop (ADR 0013), `apply -refresh-only` to repair state, and
  the node resize behaviour (the apply ends with "needs to be rebooted"
  because the module sets `automatic_reboot = false`; restart with
  `qm reboot <vmid>`). It says where each `*.tfvars` lives: gitignored, no
  backup.
- A playbook table, one row per playbook (playbook, inventory flag, required
  extra variables, when to use), and a full block for each non-trivial one:
  `site`, `cluster_init`, `join_workers`, `cluster_secrets`, `argocd-dev`,
  `argocd-prod`, `coredns_hosts`, `nfs_server`, `nfs_setup`, `vault`,
  `lan_services`, `support_tools`, `workstation`.
- `vault.yaml` has separate blocks for its jobs, which differ in inventory and
  variables: install and TLS, seed, configure dev, configure prod.
  `lan_services` has its `--limit` variants and ordering.
- Static checks: `ansible-lint`, `--syntax-check`, `terraform fmt` and
  `validate`, `pre-commit`, `scripts/check-manifests.sh`.

**`checks.md`**

- Vault: `status` and sealed, `kv list`, field-present checks that do not print
  values, snapshot age, audit-log disk.
- ArgoCD: applications and sync/health on dev and prod, spotting
  `ComparisonError` (a sealed Vault looks `Healthy`), manual sync with
  `kubectl patch`, refresh, the AVP end-to-end test.
- Cluster: nodes, pods, PVCs on `nfs-dev` and `nfs-prod`, certificates, ingress.
- NFS: `showmount -e`, `exportfs -v`.
- LAN and alerts: Gatus, Glance, Prometheus targets, Alertmanager, the
  Watchdog heartbeat, the Telegram test alert.
- Host: `free -m`, `qm list`, thin-pool usage on `pve`.
- Each check is written for both clusters through `$DEV_KC` and `$PROD_KC`.

**`access.md`**

- Getting each kubeconfig (dev over SSH from the control plane, prod from
  `terraform output -raw kubeconfig`) and the `talosconfig`.
- The `/etc/hosts` entries for the dev and prod names and the DNS-only names.
- A table of every UI and where its login comes from, never the value.
- The safe Vault CLI pattern and SSH to nodes and the Proxmox host.

**`backups-and-recovery.md`**

- Vault raft snapshots (daily, 14 kept, on `nfs-01`) and restore.
- The jobboard `tools/db-backup.sh dump|restore`, with the `kubectl exec`
  forms for dev and prod.
- What has no backup: the `*.tfvars`, the `secret.yaml` password, the private
  CA key, prod's Terraform state.
- Cleaning up retained `nfs-prod` volumes, and pointers into `rebuild.md`.

Each command comes from the file that already owns it (playbook headers, role
defaults, the existing runbook steps) and is re-checked against the committed
files when written.

### Keeping it current

`scripts/check-runbooks.sh`, run by pre-commit and the CI `scripts` job (as
`check-talos-pins.sh` is). It fails when:

- a file in `ansible/playbooks/` is not named in
  `playbooks-and-terraform.md`;
- an `ansible-playbook` command in the runbooks names a playbook, or an
  `-i inventories/...` path, that does not exist;
- a relative link in the runbooks does not resolve.

It has a small test with a fixture that proves each check can fail.

A rule goes into CLAUDE.md, through a pull request the owner reviews: commands
live in `docs/runbooks/`. A pull request that adds or changes a playbook, a
flag or an operator step updates the runbook in the same pull request, and
links the entry from its operator checklist instead of restating the command.
An ADR records the split between runbooks and `rebuild.md`.

### Sequencing

The runbook content depends on pull requests still open: `argocd-prod.yaml`,
the `dev-argocd` and `dev-grafana` names, the alert names and the step numbers
in `rebuild.md` all land with #86 to #89. The spec and plan are written now;
the implementation branch is cut from `main` after those merge, and every
command is verified against merged files. De-duplicating `rebuild.md` and
`ansible/README.md` is a separate pull request afterwards.

## Testing

No test suite, so:

- `scripts/check-runbooks.sh` and its fixture test pass; `pre-commit run
  --all-files` passes.
- A reviewer cross-checks every command block against the committed playbook
  headers, role defaults and manifests, as for the hub runbooks.
- A lookup test with the operator's own questions: from the README index,
  "run `lan_services` for Gatus only", "is Vault sealed?" and "is `monitoring`
  synced in prod?" are each reachable in two clicks.

## Documentation

The runbooks are the documentation. Alongside them: the CLAUDE.md rule and one
ADR, and a link from `README.md` and `docs/operations.md` to the runbook index.
Nothing else in the existing docs changes in this pull request.

## Pull request shape

One pull request for the runbooks, the drift guard and the CLAUDE.md rule with
its ADR, opened as a draft with this spec first. A second pull request
de-duplicates `rebuild.md` and `ansible/README.md`.

## Out of scope

- Wrapper commands (`justfile`, Makefile).
- Rewriting `rebuild.md`; only the follow-up pull request touches it.
- Editing the historical specs, plans and ADRs.
- Changing how any playbook or script behaves.
