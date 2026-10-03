# Prod Platform Hub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the empty Talos prod cluster into the hub: one ArgoCD at `argocd.mgryn.cc`, one Grafana at `grafana.mgryn.cc`, with alerting.

**Architecture:** The existing `roles/argocd` is run against a kubeconfig extracted from Terraform and bootstraps prod's ArgoCD, with AVP authenticating to Vault through a second Kubernetes auth mount. A merge to `main` then delivers the platform apps through `root-prod`: NFS provisioner, cert-manager, ingress-nginx, `kube-prometheus-stack`, `prometheus-pve-exporter`, alert rules. Four PRs. Branches are stacked (each cut from the previous branch, since the code does not depend on the earlier PR having merged) and retargeted to `main` as earlier ones merge; the owner merges in order PR 1 to PR 4.

**Tech Stack:** Terraform (telmate/proxmox, siderolabs/talos), Ansible (`kubernetes.core`), ArgoCD + AVP, Helm, kustomize, Prometheus Operator, Vault.

**Spec:** `docs/superpowers/specs/2026-10-03-prod-platform-hub-design.md`

**Plan rules (CLAUDE.md):** this plan records decisions, files, order and checks. The implementer writes the code. Exact values below are verbatim; a guessed one fails silently. Ansible and Terraform applies are **operator** steps run from the owner's workstation; an agent gives the command and reads the pasted output.

## Global Constraints

- Prod nodes: `cp1` vmid 3101 `10.0.0.110` 2048 MiB; `w1` vmid 3201 `10.0.0.111`; `w2` vmid 3202 `10.0.0.112`. Workers go to **4096** MiB. The control plane stays 2048.
- Pins, verbatim: `kube-prometheus-stack` chart `91.9.0` from `https://prometheus-community.github.io/helm-charts`; cert-manager `v1.21.2` from `https://charts.jetstack.io`; ingress-nginx `4.14.5` from `https://kubernetes.github.io/ingress-nginx`; argo-cd role default `v8.6.3`; pve-exporter image `prompve/prometheus-pve-exporter:3.10.0`.
- NFS: prod share `/srv/nfs/prod` on `nfs-01` (`scsi2`, 50G), StorageClass `nfs-prod`. Export clients are the two worker addresses, never a subnet (ADR 0010).
- Vault: address `vault.mgryn.cc:8200`; mount `kv-prod`; the prod Kubernetes auth mount is `kubernetes-prod`, policy `argocd-read-prod`, role `argocd`, ServiceAccount `argocd-repo-server` in namespace `argocd`. AVP reads `kv-prod` only.
- Secrets appear in committed manifests only as `<path:kv-prod/data/...#FIELD>`. kv-prod paths: `cert-manager/cloudflare` (`API_TOKEN`), `monitoring/grafana` (`admin-user`, `admin-password`), `monitoring/alertmanager` (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`), `monitoring/pve-exporter` (`PVE_USER`, `PVE_TOKEN_NAME`, `PVE_TOKEN_VALUE`).
- Names: `argocd.mgryn.cc` and `grafana.mgryn.cc` (prod); `dev-argocd.mgryn.cc` (dev, transitional). DNS is two grey-cloud Cloudflare A records per name, `10.0.0.111` and `10.0.0.112`. Certificates come from cert-manager DNS-01 (ADR 0008).
- Prometheus: PVC 20Gi on `nfs-prod`, `retention.size` 15GB; Grafana PVC 5Gi; remote-write receiver on. Namespace `monitoring`.
- Pool alert threshold: thin-pool `data%` 80%.
- Commits: Conventional, subject at most 50 characters, lowercase, imperative; types `feat fix refactor docs chore ops`. No `Co-Authored-By`, no generated-with line, in commits or PR bodies. Branch before the first commit; never `--no-verify`.
- Merge is the deploy. Never merge; push the branch, open the PR with `gh`.
- `terraform apply`: read the plan summary first; a `destroy` not intended is a stop (ADR 0013).
- Each PR updates README table/diagram, `docs/rebuild.md` and `docs/operations.md` for what it changes.

## Review Focus

- A sealed `vault-02`: prod apps with placeholders show `Unknown` while health says `Healthy`. Task 11 exercises it; docs name `vault status` as the first check.
- A worker dead or rebooting: both A records still answer one host. Task 17's Gatus checks name each hub URL.
- Two ArgoCDs apply the same `argocd/base/`: the prod instance must not break dev's AppProject or the shared `vault-auth` ServiceAccount. Task 8 checks both clusters sync clean.
- NFS exported to a subnet or to everyone by an empty client list. Task 3 checks `showmount -e` lists exactly two addresses.
- A rule that references a metric which does not exist alerts on nothing and looks healthy. Task 20 requires the pool metric be observed in Prometheus before the rule is written.
- Telegram token, Grafana password, Cloudflare token committed as literals. Task 22 greps the diff.

---

# PR 1 — host and nodes (branch `hub-nodes`)

### Task 1: Workers to 4 GiB in the example and docs

**Files:**
- Modify: `terraform/environments/prod/prod.tfvars.example` (worker `memory`), `README.md` and `docs/rebuild.md` wherever prod sizes are stated

**Interfaces:**
- Produces: the documented node sizes that Task 2 applies.

- [x] Branch `hub-nodes` from `main`; `pre-commit install` if `.git/hooks/commit-msg` is missing.
- [x] Set `w1` and `w2` memory to 4096 in `prod.tfvars.example`; update every doc that says prod runs 2G workers (grep `2G`, `2048`, `6G` in README, rebuild, operations).
- [x] Verify: `cd terraform/environments/prod && terraform fmt -check && terraform validate && terraform test`. Expected: all runs pass, as before.
- [x] Commit `docs: size prod workers at 4G for the hub`.

### Task 2: Apply the resize [operator]

**Files:** none (`prod.tfvars` is gitignored and unbacked-up; edit it by hand).

- [ ] Operator sets `w1`/`w2` `memory = 4096` in `environments/prod/prod.tfvars`.
- [ ] `terraform plan -var-file=prod.tfvars`. Expected: `2 to change, 0 to add, 0 to destroy`, only `memory` on `w1`/`w2`. Any destroy: stop.
- [ ] Apply once the plan is as expected; both workers reboot together (cluster is empty).
- [ ] Verify on `pve`: `free -m` shows `available` of at least 1500; `qm list` shows 3201 and 3202 at 4096. Verify `kubectl get nodes` (kubeconfig from `terraform output -raw kubeconfig` into a temp file) shows three Ready within a few minutes. Expected: all `Ready`.
- [ ] Record the post-apply `available` figure in the PR description.

### Task 3: `nfs-prod` export to the workers

**Files:**
- Modify: `ansible/roles/nfs_server/defaults/main.yaml` (`nfs_server_prod_clients`), `ansible/secret.yaml.example` (`host_ips` gains the worker keys)
- Operator edits: `ansible/secret.yaml` (ansible-vault)

**Interfaces:**
- Consumes: `host_ips` keys. New keys `talos-w1` (`10.0.0.111`) and `talos-w2` (`10.0.0.112`).
- Produces: an export line for `/srv/nfs/prod` limited to those two addresses.

- [x] Add a `nfs_server_prod_nodes` list of the two keys and derive `nfs_server_prod_clients` the same way the dev clients are derived; update the "empty until a prod cluster exists" comment.
- [x] Add the two `host_ips` entries to `secret.yaml.example`; operator adds them to `secret.yaml`.
- [x] Verify: `ansible-lint ansible/roles/nfs_server` and `ansible-playbook ansible/playbooks/nfs_server.yaml --syntax-check -e @secret.yaml --ask-vault-pass`.
- [ ] Operator runs the playbook with `-i inventories/shared`. Then `showmount -e 10.0.0.<nfs-01>`: the prod path lists exactly `10.0.0.111` and `10.0.0.112`; the dev path is unchanged. `exportfs -v` on `nfs-01` shows `no_root_squash` on both.
- [x] Commit `ops: export nfs-prod to the prod workers`.

### Task 4: kv-prod seed entries

**Files:**
- Modify: `ansible/secret.yaml.example` (`vault_kv.kv-prod` block, each path commented like the dev ones)

**Interfaces:**
- Produces: the five kv-prod paths from Global Constraints, which Tasks 14-21 read.

- [x] Add the block with placeholder values only; reuse the existing comment style (permissions, what reads it). Telegram values are the same bot Gatus uses.
- [ ] Operator fills `secret.yaml` (`PVE_*` values are filled after Task 19) and seeds with `vault.yaml -e vault_seed=true -e vault_token=...`.
- [x] Verify: `vault kv get kv-prod/cert-manager/cloudflare` shows `API_TOKEN` set; no value is printed into the PR.
- [x] Commit `docs: seed example for kv-prod`.
- [ ] Open the PR; operator merges after Tasks 2-4 are verified. Branch cleanup per CLAUDE.md.

---

# PR 2 — hub bootstrap (branch `hub-bootstrap`)

### Task 5: Vault Kubernetes auth for prod

**Files:**
- Modify: `ansible/roles/vault/defaults/main.yaml` (`vault_k8s_clusters` gains `prod`), `ansible/roles/vault/tasks/k8s_auth_cluster.yaml`, `ansible/roles/vault/tasks/validate_clusters.yaml`, `ansible/roles/vault/templates/k8s-policy.hcl.j2` only if the policy name or mount is hard-coded

**Interfaces:**
- Consumes: the `vault-auth` ServiceAccount and `vault-auth-token` Secret in namespace `argocd`, created by `argocd/base/vault-auth-delegator.yaml` once `argocd-config` (Task 8) syncs it during Task 11.
- Produces: auth mount `kubernetes-prod`, policy `argocd-read-prod` reading `kv-prod/data/*`, role `argocd`.

The dev entry reads the reviewer JWT and CA over SSH with `kubectl` on the control plane (`control_plane_host`). Talos has no SSH. This task must teach the role a second source for a cluster with no `control_plane_host`: read the same Secret and the cluster CA through a kubeconfig on the workstation (`kubernetes.core.k8s_info`, delegated to localhost). Dev's behaviour must not change.

- [x] Add the `prod` entry: `kv_mount: kv-prod`, `auth_path: kubernetes-prod`, `api_host: 10.0.0.110` (verbatim from the node table), policy and role names from Global Constraints.
- [x] Make `control_plane_host` optional in validation; require exactly one of `control_plane_host` or a kubeconfig path variable per cluster, with a failure message naming the cluster.
- [x] Verify: `ansible-lint ansible/roles/vault`; `--syntax-check` on `vault.yaml`; run the role in `--check` against dev and confirm no diff for the dev mount.
- [x] Commit `feat: vault kubernetes auth for the prod cluster`.

### Task 6: argocd role takes the auth mount and host as variables

**Files:**
- Modify: `ansible/roles/argocd/defaults/main.yaml` (`argocd_avp_config` gains the mount path; new `argocd_vault_auth_path`, default `kubernetes`; new `argocd_ingress_host`, default `argocd.mgryn.cc`; new `argocd_repo_server_host_aliases`, default empty list, rendered into the chart's repo-server `hostAliases`), the role's Helm values for the ingress host and ArgoCD `url`

**Interfaces:**
- Produces: variables `argocd_vault_auth_path`, `argocd_ingress_host`, `argocd_repo_server_host_aliases` that Tasks 7 and 9 set per environment. Defaults must reproduce today's dev render byte for byte except the host.

- [x] Confirm which AVP setting selects the Vault auth mount (the AVP docs name it for `AVP_AUTH_TYPE: k8s`) and use that key; the value must be in the pod-annotation checksum so a change rolls the repo-server (the role already hashes `argocd_avp_config`).
- [x] Verify: `ansible-lint ansible/roles/argocd`; `--syntax-check` on `argocd-dev.yaml`.
- [x] Commit `refactor: argocd role takes vault mount and host`.

### Task 7: `argocd-prod.yaml` playbook

**Files:**
- Create: `ansible/playbooks/argocd-prod.yaml`

**Interfaces:**
- Consumes: Task 6's variables. Sets `argocd_vault_auth_path: kubernetes-prod`, `argocd_ingress_host: argocd.mgryn.cc`, `argocd_nodeport_enabled: true`, and `argocd_context_kubeconfig` from an extra var `prod_kubeconfig`.
- Produces: the playbook the operator runs in Task 11.

- [x] Hosts `localhost`, `connection: local`, no apt/Helm-install pre-tasks (Helm and `python3-kubernetes` live on the workstation); fail early with a clear message if `prod_kubeconfig` is unset or `helm` is missing.
- [x] Decide the Vault name path: pods need `vault.mgryn.cc`. Preferred: set `argocd_repo_server_host_aliases` (Task 6) to `vault.mgryn.cc` with Vault's address (`host_ips['vault-02']`) in the prod playbook, because the CoreDNS ConfigMap on Talos is Talos-managed. Confirm the chart exposes `repoServer.hostAliases` with `helm template`; if it does not, fall back to patching CoreDNS and say which in the ADR.
- [x] Verify: `ansible-lint ansible/playbooks/argocd-prod.yaml` and `--syntax-check -e @secret.yaml -e prod_kubeconfig=/tmp/x --ask-vault-pass`.
- [x] Commit `feat: argocd playbook for the prod cluster`.

### Task 8: prod `argocd-config`, drop stale prod Applications, project sources, ADR 0024

**Files:**
- Create: `argocd/environments/prod/applications/argocd-config.yaml` (same shape and the same two comments as dev's: no finalizer, `prune: false`), `docs/decisions/0024-hub-in-prod.md`
- Modify: `docs/decisions/README.md` (index), `argocd/base/projects.yaml` (`sourceRepos` gains `https://prometheus-community.github.io/helm-charts`, moved here from the old Task 12 because both ArgoCDs sync `argocd/base` and a repo not yet allowed refuses its Application)
- Delete: `argocd/environments/prod/applications/nfs.yaml` and `monitoring.yaml`. These are pre-Talos leftovers; once the operator applies `root-prod` in Task 11 they would sync from `main` and deploy stale manifests before PR 3 replaces them. Keep the overlay directories under `argocd/apps/` until PR 3 rewrites them.

- [x] Application watches `argocd/base`, project `homelab`, destination `https://kubernetes.default.svc`, namespace `argocd`.
- [x] ADR 0024 records: hub in prod; bootstrap via the role with an extracted kubeconfig; second Vault auth mount; `hostAliases` (or the fallback); transitional `dev-argocd` name. Leave sections for PR 3 and PR 4 to extend with their decisions.
- [x] Verify: `scripts/check-manifests.sh`; `pre-commit run --all-files`. Both clusters' ArgoCDs read `argocd/base`, so confirm `kustomize build argocd/base` is unchanged by this PR.
- [x] Commit `feat: prod argocd-config and hub ADR`.

### Task 9: Dev's ArgoCD moves to `dev-argocd.mgryn.cc`

**Files:**
- Modify: `ansible/playbooks/argocd-dev.yaml` (sets `argocd_ingress_host: dev-argocd.mgryn.cc`), any dev Ingress or ConfigMap that names `argocd.mgryn.cc`, `ansible/roles/glance/defaults/main.yaml` if it links the old name, `docs/operations.md`, `docs/rebuild.md`, `README.md`

- [x] `grep -rn "argocd.mgryn.cc"` outside `docs/superpowers`; change each hit that means dev.
- [x] Verify: `ansible-lint`, syntax check on `argocd-dev.yaml`, `scripts/check-manifests.sh`.
- [x] Commit `ops: dev argocd answers on dev-argocd.mgryn.cc`.

### Task 10: Docs for the bootstrap

**Files:**
- Modify: `docs/rebuild.md` (prod bootstrap section: extract kubeconfig, run the play, apply `argocd/base/projects.yaml` and prod's `app-of-apps.yaml` by hand as dev does, then Vault configure, then verify), `docs/operations.md` (URLs, kubeconfig extraction, break-glass NodePort), `README.md`

- [x] Write the ordered operator runbook from Task 11, including the chicken-and-egg: Vault's prod auth needs the `vault-auth` ServiceAccount, which `argocd-config` syncs without AVP; apps with placeholders sync only after Vault is configured.
- [x] Commit `docs: prod hub bootstrap runbook`. Open the PR (draft until Task 11 passes), then `gh pr ready`.

### Task 11: Bootstrap the hub [operator]

- [ ] Merge PR 2. Operator: `terraform output -raw kubeconfig` to a temp file (mode 600, delete afterwards); run `argocd-dev.yaml` (rename), then `argocd-prod.yaml -e prod_kubeconfig=<tmp>`; then `kubectl apply -f argocd/base/projects.yaml` and `-f argocd/environments/prod/applications/app-of-apps.yaml`.
- [ ] Verify pods: `kubectl -n argocd get pods`; expected: every pod `Running` or `Completed`, `repo-server` 2/2 or 3/3 (not `Init`).
- [ ] Wait for `argocd-config` `Synced`, then run `vault.yaml -e vault_configure=true -e vault_token=... -i inventories/shared -i inventories/dev`. Expected: `vault read auth/kubernetes-prod/config` shows `kubernetes_host https://10.0.0.110:6443`.
- [ ] Verify AVP end to end with a throwaway Application that renders one `<path:kv-prod/data/monitoring/grafana#admin-user>`; expected: `Synced`, no `ComparisonError`. Delete the throwaway.
- [ ] Verify names: `/etc/hosts` maps `argocd.mgryn.cc` to a worker; login page loads over the NodePort; `dev-argocd.mgryn.cc` still lists dev's Applications `Synced`.
- [ ] Seal drill: confirm `docs/operations.md` names `vault status` on `vault-02` (`VAULT_ADDR=https://10.0.0.133:8200`) as the first check when a prod app goes `Unknown`.

---

# PR 3 — platform apps (branch `hub-platform`)

### Task 12: (folded into Task 8)

The `sourceRepos` change ships with PR 2 in Task 8. Nothing to do here; the number stays so later references hold.

### Task 13: NFS provisioner and StorageClass for prod

**Files:**
- Modify: `argocd/apps/nfs_provisioner/prod/*`; Create: `argocd/environments/prod/applications/nfs.yaml` (Task 8 deleted the stale one); the StorageClass `nfs-prod` is the default class

**Interfaces:**
- Produces: StorageClass `nfs-prod`, default; the provisioner's NFS server `10.0.0.<nfs-01>` and path `/srv/nfs/prod`, both taken from `host_ips` / the nfs_server role defaults, not from the old overlay.

- [ ] Check every field of the leftover overlay against current values (server, path, image tag, namespace); fix what is stale. Add the `argocd.argoproj.io/sync-wave` annotation that orders it first.
- [ ] Verify: `kustomize build argocd/apps/nfs_provisioner/prod`; `scripts/check-manifests.sh`.
- [ ] Commit `feat: nfs-prod storage class on the prod cluster`.

### Task 14: cert-manager and issuers in prod

**Files:**
- Create: `argocd/environments/prod/applications/cert-manager.yaml`, `cert-manager-issuers.yaml`; `argocd/apps/cert-manager-issuers/prod/` (overlay of the existing base reading `kv-prod`)

- [ ] Mirror the dev Applications; chart pin `v1.21.2`; issuers production and staging; Cloudflare token via `<path:kv-prod/data/cert-manager/cloudflare#API_TOKEN>`.
- [ ] Sync waves after the StorageClass. Verify: `kustomize build` on the overlay; `helm template` is not needed (Helm values only).
- [ ] Commit `feat: cert-manager on the prod cluster`.

### Task 15: ingress-nginx in prod

**Files:**
- Create: `argocd/environments/prod/applications/ingress-nginx.yaml`, `argocd/apps/ingress-nginx/prod/values.yaml`

- [ ] Same shape as dev (DaemonSet, host ports 80/443, `ServerSideApply`), chart pin `4.14.5`. The `argocd/apps/ingress-nginx/*` directories are Helm inputs, not kustomize overlays.
- [ ] Verify: `helm template` with the values; expected: a DaemonSet, no Service of type LoadBalancer.
- [ ] Commit `feat: ingress-nginx on the prod cluster`.

### Task 16: `kube-prometheus-stack`, secrets app, remove the old overlay

**Files:**
- Create: `argocd/environments/prod/applications/monitoring.yaml` (Task 8 deleted the stale one), `monitoring-secrets.yaml`, `argocd/apps/kube-prometheus-stack/prod/values.yaml`, `argocd/apps/monitoring-secrets/prod/` (kustomize: Secrets with `<path:...>` placeholders)
- Delete: `argocd/apps/monitoring/prod/`

**Interfaces:**
- Consumes: StorageClass `nfs-prod`; kv-prod `monitoring/grafana` and `monitoring/alertmanager`.
- Produces: namespace `monitoring`, Services Prometheus and Grafana, `ServiceMonitor` and `PrometheusRule` discovery for the whole cluster (selectors must not be limited to the chart's release label, or Task 20-21 rules are ignored).

- [ ] Helm values: Prometheus PVC 20Gi `nfs-prod`, `retention.size` 15GB, remote-write receiver on, rule and monitor selectors open; Grafana PVC 5Gi, admin credentials from an `existingSecret`, ingress host `grafana.mgryn.cc` with the production ClusterIssuer; Alertmanager reads its Telegram token and chat id from a mounted Secret (never an inline value). Secrets come from the separate kustomize app so no placeholder sits in a Helm values file.
- [ ] `ServerSideApply` for the chart (large CRDs). Add the CRD-size caveat as a comment where it is set.
- [ ] Verify: `helm template` (chart `91.9.0`) with the values; `kustomize build argocd/apps/monitoring-secrets/prod`; `scripts/check-manifests.sh`; grep the diff for any literal token.
- [ ] Commit `feat: kube-prometheus-stack on the prod cluster`.

### Task 17: Gatus checks and docs

**Files:**
- Modify: `ansible/roles/gatus/defaults/main.yaml` (checks for `argocd.mgryn.cc` and `grafana.mgryn.cc`, each with `[CONNECTED] == true` like the others), `docs/operations.md`, `README.md` (table and Mermaid diagram), `docs/decisions/0024-hub-in-prod.md` (kube-prometheus-stack decision)

- [ ] Verify: `ansible-lint ansible/roles/gatus`.
- [ ] Commit `ops: gatus checks for the prod hub`; open the PR, draft until Task 18 passes.

### Task 18: Roll out the platform [operator]

- [ ] Cloudflare: four grey-cloud A records, `argocd` and `grafana` each to `10.0.0.111` and `10.0.0.112`. Workstation `/etc/hosts` points both names at a worker.
- [ ] Merge PR 3. Watch `kubectl -n argocd get applications`; expected: all `Synced`/`Healthy` after about 3 minutes plus chart pulls.
- [ ] Verify storage: `kubectl get pvc -A`; expected: `Bound` on `nfs-prod`, none `Pending`.
- [ ] Verify certificates: `kubectl get certificate -A`; expected: `Ready=True`. Debug with the staging issuer first; production allows 5 failures per hostname per hour.
- [ ] Verify serving: `curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: grafana.mgryn.cc' https://10.0.0.111/` and the same for `.112`; expected `302` or `200`. Grafana's Prometheus datasource: `Connection successful`.
- [ ] `ansible-playbook ... --limit gatus`; expected: the two new endpoints green in Gatus.
- [ ] Host check: `free -m` on `pve`; `available` still above 1000 MiB.

---

# PR 4 — alerting (branch `hub-alerting`)

### Task 19: pve-exporter token in the bootstrap script

**Files:**
- Modify: `scripts/pve-bootstrap.sh` (new step `pve-exporter`, modelled on `step_glance`: user `pve-exporter@pve`, role `PVEAuditor`, token `pve-exporter`, secret printed once), `scripts/tests/pve-bootstrap.test.sh`, `docs/rebuild.md`

- [ ] Add the step to `ALL_STEPS` and the usage line; add stub-test cases for create and for already-exists, as the Glance step has.
- [ ] Verify: `scripts/tests/pve-bootstrap.test.sh` passes; `shellcheck scripts/pve-bootstrap.sh`; `scripts/check-talos-pins.sh` unchanged.
- [ ] Commit `feat: pve-exporter token in the host script`.
- [ ] Operator (can wait for the deferred real run of the script): run the step, put the printed secret into `secret.yaml`, seed `kv-prod/monitoring/pve-exporter`.

### Task 20: pve-exporter app, and the pool metric

**Files:**
- Create: `argocd/environments/prod/applications/pve-exporter.yaml`, `argocd/apps/pve-exporter/prod/` (Deployment with image `prompve/prometheus-pve-exporter:3.10.0`, Service, `ServiceMonitor`, Secret with `<path:kv-prod/data/monitoring/pve-exporter#...>` placeholders)

- [ ] Verify: `kustomize build`; `scripts/check-manifests.sh`.
- [ ] Commit `feat: pve-exporter on the prod cluster`.
- [ ] After merge [operator]: in Prometheus, find the series for `local-lvm` size and usage (`pve_disk_size_bytes` and `pve_disk_usage_bytes` are the expected names; confirm in the UI) and paste them into the PR. The rule in Task 21 is written from what is observed, not from this guess.

### Task 21: Rules, SLOs and Alertmanager route

**Blocked on the operator** until Task 20's observation is pasted into PR 4: the thin-pool rule expression comes from the observed series. Write the other rules and the route first; hold the pool rule until the series is known.

**Files:**
- Create: `argocd/apps/alerts/prod/` (kustomize of `PrometheusRule`s), `argocd/environments/prod/applications/alerts.yaml`
- Modify: `argocd/apps/kube-prometheus-stack/prod/values.yaml` (Alertmanager route to Telegram, a `Watchdog` route that goes nowhere)

- [ ] Rules: node not ready, pod crash looping, certificate expiry within 14 days, NFS provisioner unavailable, Prometheus PVC above 80%, thin-pool `data%` above 80% (expression from Task 20's observed series), plus burn-rate SLO rules over ingress request ratios (availability target 99%, fast and slow windows).
- [ ] Write rules cluster-agnostically (no hard-coded `cluster` label values) so dev's metrics are covered by sub-project 4 without a rewrite.
- [ ] Verify: `promtool check rules` on the rendered rules (extract with `kustomize build`); `scripts/check-manifests.sh`.
- [ ] Commit `feat: prod alert rules, slos and telegram route`.

### Task 22: Docs, review, land

- [ ] Extend ADR 0024 with the pve-exporter decision; README table and diagram; `docs/operations.md` alert and silence procedures.
- [ ] Verify: `grep -rEn "token|password|secret" $(git diff main --name-only)` shows only placeholders and doc prose; `pre-commit run --all-files`.
- [ ] Commit `docs: alerting runbook for the prod hub`; open the PR.

### Task 23: Prove alerting [operator]

- [ ] After merge: Alertmanager's `Watchdog` shows firing; trigger a test alert (`amtool alert add` or a temporary rule with `vector(1)`); expected: a Telegram message within about 2 minutes. Remove the test rule.
- [ ] Confirm `data%` is queryable and below 80%: record the value.
- [ ] Update the ticks in this plan; `gh pr ready 84` once all four PRs have merged and the spec PR is the last open item.

---

## Self-review notes

- **Spec coverage:** every spec section maps to a task: control path (7, 11), GitOps path (8, 10), apps (13-16), NFS and secrets (3, 4, 16), monitoring and alerting (16, 19-21), DNS and rename (9, 17, 18), worker RAM (1-2), failure modes (Review Focus), documentation (10, 17, 22), PR shape (headings).
- **Deviation from the spec:** the spec says the play ends by applying `root-prod`. Dev applies `projects.yaml` and the app-of-apps by hand after the play, so prod does the same (Tasks 10, 11): one bootstrap pattern.
- **Found while planning, not in the spec:** Vault's Kubernetes auth has a dev entry only and reads its reviewer token over SSH, so Task 5 adds a prod entry and a kubeconfig-based read.
- **Open for the implementer to settle by checking:** the AVP key for the auth mount (Task 6), `repoServer.hostAliases` support (Task 7), the pool metric's real name (Task 20).
