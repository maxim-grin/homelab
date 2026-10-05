# Dev as a Spoke — Design

Roadmap sub-project 4 ([2026-09-26](2026-09-26-homelab-roadmap-design.md)).
The prod hub ([2026-10-03](2026-10-03-prod-platform-hub-design.md)) is
rolled out and verified. This points it at dev, retires dev's own ArgoCD,
and makes dev safe to rebuild from scratch at any time.

## Problem

Dev still runs as a standalone cluster:

- its own ArgoCD (`dev-argocd.mgryn.cc`), watching `argocd/environments/dev`
- hand-rolled monitoring manifests, not the chart prod uses
- VMs named `ubuntu-k8s-master-01` and `ubuntu-k8s-worker-01`, not the
  `<distro>-<env>-<role>` pattern prod uses
- one piece of state git does not hold: jobboard's Postgres, on an
  `nfs-dev` PVC that is deleted with the PVC
- Application names that collide with prod's (`nfs`, `cert-manager`,
  `monitoring`), so one ArgoCD cannot hold both as they are

The goal is the roadmap's: one ArgoCD showing both clusters, and a dev
that rebuilds with one Terraform apply, one bootstrap playbook and one
registration playbook, after which prod syncs everything else.

## Decisions

| Question | Decision |
| --- | --- |
| Dev distribution | Stays kubeadm on Ubuntu. Talos for dev is not ruled out later; not now |
| Shape | Two PR series: A converts dev to a spoke in place, B rebuilds and renames it |
| Application naming | ApplicationSets for both clusters, names `<cluster>-<app>` (`prod-nfs`, `dev-nfs`) |
| Prod's existing Applications | Deleted and recreated by the set. Prod holds no valuable data yet |
| Registering dev | Declarative cluster Secret labelled `env=dev`, token in Vault, written by an Ansible play |
| Dev monitoring | Prometheus Operator in agent mode, remote-writing to prod |
| Remote-write endpoint | Prod's ingress, TLS plus basic auth, credentials in Vault |
| Vault access for dev apps | Prod ArgoCD's policy also reads `kv-dev/`; spokes read only their own |
| Cutover | Cascade delete of dev's Applications; prod's set recreates them |
| jobboard data | One dump to the workstation before cutover, restored into prod in sub-5. Dev's DB is empty afterwards |
| Dev afterwards | Holds no state, so it is rebuildable at any time |

## Prerequisite: the dump

Before any step that deletes dev's Applications, the jobboard database is
dumped off the cluster.

- `tools/db-backup.sh dump` (job-board PR #35) against dev, to the
  operator's workstation, never to `nfs-01`.
- The file is validated: it is non-empty and `pg_restore --list` reads it.
- A second copy goes somewhere off the workstation. It is the only copy
  of that data.
- Jobboard stays down from cutover until sub-5 restores the dump into
  prod's Postgres.

## Series A: dev becomes a spoke

Dev's VMs stay as they are throughout.

**A1, hub-side preparation (prod only).**

- Widen prod ArgoCD's Vault policy to read `kv-dev/`. Amends ADR 0011 and
  ADR 0024: the hub reads both KV trees, a spoke reads only its own.
- Convert prod's Applications to ApplicationSets. The cluster generator
  selects `env=prod`; names are `prod-<app>`. Deleting and recreating
  cert-manager reissues the `argocd.mgryn.cc` certificate, and
  production Let's Encrypt allows five duplicates a week, so the rename
  is rehearsed against `letsencrypt-staging` first.
- Prod's Prometheus receiver gets an ingress with TLS and basic auth.
  Credentials live in `kv-prod` and `kv-dev`.

**A2, register dev.**

- A playbook creates the `argocd-manager` ServiceAccount and token on dev
  and writes token and CA to `kv-prod`.
- A committed cluster Secret labelled `env=dev` carries AVP placeholders
  for them, in prod's `argocd` namespace.

**A3, dev's ApplicationSet and cutover.**

- A set selects `env=dev` and generates `dev-<app>` for ingress-nginx,
  cert-manager, cert-manager issuers, nfs, jobboard and monitoring.
- Dev's monitoring becomes the agent-mode operator install, remote-writing
  to prod with a `cluster=dev` external label.
- Cutover, as a runbook entry: delete dev's Applications with cascade, let
  prod's set recreate them, check each. Jobboard comes back with an empty
  database.
- Dev's ArgoCD is uninstalled with its `app-of-apps`, `argocd-config`,
  `dev-argocd.mgryn.cc` ingress and the hand-rolled monitoring. The
  `argocd/environments/dev` directory goes.

## Series B: rebuild and rename

**B1, new VMs.**

- `terraform/environments/dev` creates `kubeadm-dev-cp1` and
  `kubeadm-dev-w1`, 3G each, with new vmids. The old VMs are destroyed in
  a separate step once the new ones are verified. Creating fresh avoids an
  in-place rename, which would need `moved` blocks (ADR 0013) and would
  leave the Proxmox name, the hostname and the kubeadm node name
  disagreeing.
- The existing kubeadm roles bootstrap the cluster, including the CoreDNS
  hosts play for `vault.mgryn.cc` and Vault's `kubernetes-dev` auth.
- Re-running A2's registration playbook reconnects prod's ArgoCD, and the
  `dev-*` set restores every app.
- Old `nfs-dev` PVC directories stay on `nfs-01` until the post-sub-5 SSD
  rebuild.

**B2, the proof and the docs.**

- A runbook entry "rebuild dev": the commands in order, a check after
  each, and what the first real run caught.
- `docs/rebuild.md` gets the dev flow.

## Verification

No test suite, so each step is checked on the thing itself.

- After A1: every `prod-*` Application Synced and Healthy;
  `argocd.mgryn.cc` serves a valid certificate; an authenticated
  remote-write to the receiver succeeds and an unauthenticated one does
  not.
- After A2: `argocd cluster list` shows dev Successful.
- After A3: every `dev-*` Application Synced and Healthy; the jobboard
  Ingress answers with the right `Host:` header; series with
  `cluster=dev` appear in prod's Prometheus.
- After B1: nodes Ready, and ArgoCD reconnects without manual edits.
- `scripts/check-manifests.sh` must render the ApplicationSets and prod
  Application CRs it skips today; this series adds that.

## Risks

- **Cascade delete wipes `nfs-dev` PVC data.** Safe only because the dump
  is taken and validated first.
- **Let's Encrypt reissue** on the prod recreate: staging first.
- **A sealed Vault looks healthy.** Apps go `Unknown`, health stays
  `Healthy`. `vault status` is the first check.
- **Prod is the only deploy path for dev.** The roadmap accepted this.
- **Misplaced ApplicationSet template keys are ignored silently**, as with
  `managedNamespaceMetadata`; `check-manifests.sh` stays strict.

## Documentation

- ADR 0026, dev is a spoke. It amends the Vault policy rule in ADRs 0011
  and 0024.
- README table and Mermaid diagram, `docs/rebuild.md`,
  `docs/runbooks/`: updated in the PR that changes them.
- CLAUDE.md: the dev/prod Application names and `dev-argocd` references.

## Out of scope

- Talos for dev.
- Deploying jobboard to prod and moving `jobs.mgryn.cc` (sub-5).
- Kargo, Image Updater, off-site backups.
