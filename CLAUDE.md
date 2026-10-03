# homelab

One Dell box running Proxmox VE 9 on a single internal SSD. Terraform
provisions the VMs, Ansible configures them, ArgoCD delivers applications to
a kubeadm Kubernetes cluster. See `README.md` for what runs; this file is
about _working on_ it.

**Rebuilding after a disk failure or replacement starts at
[docs/rebuild.md](docs/rebuild.md).** The host underneath — repositories,
users, API token, resource pools, and the VM template every machine clones —
is set up by `scripts/pve-bootstrap.sh`, not Terraform.

## The thing that catches everyone

**ArgoCD syncs `main` from GitHub, not your working copy.** A change is
invisible to the cluster until it is on GitHub's `main`. A commit is not a
deploy, a pushed branch is not a deploy, and an open pull request is not a
deploy — the merge is. This is the single most common way an "applied"
change appears to do nothing.

## Stack

Terraform with `telmate/proxmox` (pinned `3.0.2-rc10`, local state), Ansible
with `kubernetes.core`, kubeadm, ArgoCD app-of-apps, kustomize for plain
manifests and Helm for third-party charts. CI on GitHub Actions
(`.github/workflows/ci.yaml`), no test suite.

`dev` is the kubeadm cluster. `terraform/environments/prod` is the Talos
cluster: three nodes through the `siderolabs/talos` provider, applied from
the operator's workstation; the prod app-of-apps delivers the hub platform apps.
`terraform/environments/shared` holds `nfs-01`, `vault-02` and the LAN LXCs.
Their prod halves (`nfs-prod`, `kv-prod`) stay unused until the hub platform
lands.

## Layout

```txt
ansible/          roles/ + playbooks/, inventory per environment,
                  secrets in an ansible-vault file
argocd/           base/       AppProject
                  apps/       kustomize bases and dev overlays, or Helm values
                  environments/dev/applications/  Application CRs, synced by root-dev
terraform/        modules/    reusable ubuntu-vm, ubuntu-k8s, lxc,
                              nfs-server, vault-vm, talos-node
                  environments/dev/     the dev machines
                  environments/prod/    the Talos prod cluster
                  environments/shared/  nfs-01, vault-02 and the LAN LXCs;
                                        prod shares and KV ready, unused
docs/rebuild.md   how to recreate all of it from a bare Proxmox install
docs/operations.md  day-to-day: UIs, applying, jobboard versions
```

## How a change reaches the cluster

Three different paths, and mixing them up wastes an afternoon:

| Layer                       | Applied by                                                                              | Takes effect                |
| --------------------------- | --------------------------------------------------------------------------------------- | --------------------------- |
| VMs, disks, network         | `terraform apply -var-file=<env>.tfvars` in `environments/dev`, `shared` or `prod` | immediately                 |
| OS, packages, cluster       | `ansible-playbook … -e @secret.yaml --ask-vault-pass`                                   | immediately                 |
| Kubernetes workloads        | **PR merged to `main`**, then ArgoCD syncs                                              | on Argo's next poll, ~3 min |
| `argocd/base/projects.yaml` | **PR merged to `main`**, then ArgoCD syncs                                              | on Argo's next poll, ~3 min |

That last row is a bootstrap-only exception: `root-dev` only watches
`argocd/environments/dev/applications/`, so the AppProject that authorises
everything cannot be synced by `root-dev` itself before it exists — one
`kubectl apply -f argocd/base/projects.yaml` by hand gets the cluster off
the ground. After that, the `argocd-config` Application owns
`argocd/base/` and syncs it on every push. A new Helm chart repository
must be added to its `sourceRepos` allowlist, or ArgoCD refuses the
Application with "application repo is not permitted".

## Branch first

```bash
pre-commit install               # once per clone, before any work starts
git checkout -b <change-name>    # before the first commit, not after
```

Every pre-commit check passes before a commit lands. Fix what a hook
reports; never bypass it with `--no-verify`.

`main` receives only finished work, and only through a pull request — never
a local merge, never a direct push. For anything larger than a one-file fix,
use the `superpowers` plugin's skills by name — brainstorming to agree the
shape, writing-plans to sequence it, requesting-code-review before landing,
finishing-a-development-branch for its pre-merge checks (stop before it
merges; see below). Invoke them with the Skill tool; do not approximate them
by hand.

**Plans record decisions, not finished code.** A plan says what each
task must do, which files it touches, in what order, and how to check
it: the verification command and what its output should be. The
implementer writes the code. Exact values — versions, digests, names,
paths — stay verbatim in the plan, because a guessed one fails
silently. This overrides the writing-plans skill's default of a
complete code block in every step.

**When a supervisor agent drives subagents, the supervisor owns the plan's
checkboxes** — ticked when a task is implemented _and_ verified by review,
never on the implementer's report alone. Implementers see only an extracted
brief and never the plan file, so nothing else can record progress.

### Landing work

**Do not merge to `main`. Push the branch and open a pull request with
`gh`.** The repository owner reviews and merges; an agent's job ends at the
open PR. Here the merge _is_ the deploy — ArgoCD syncs `main` — so the
merge button stays with the person who will watch the cluster roll.

```bash
git push -u origin <change-name>
gh pr create --base main --head <change-name> --title "..." --body-file <file>
```

`gh` authenticates from `~/.config/gh/hosts.yml`. A `GH_TOKEN` or
`GITHUB_TOKEN` in the environment silently overrides the logged-in account;
if `gh` starts returning 403, check `gh auth status` first.

**A spec opens the pull request.** As soon as a brainstorming spec is
committed, push the branch and open a draft, so the design is reviewable
on GitHub before any plan or code exists:

```bash
gh pr create --draft --base main --head <change-name> --title "..." --body-file <file>
```

The plan and implementation that follow land in the same draft; `gh pr
ready <N>` once the branch's work is finished and verified. A draft
cannot be merged, so this never shortcuts review.

One PR per logical change. A repo-wide convention change and an unrelated
feature are two PRs, not one — the title can only describe one of them
honestly. A plan's operator steps that said "merge and push `main`" now mean
"merge the PR".

GitHub merges with a merge commit (`Merge pull request #N from …`) and
deletes the head branch. Afterwards, locally: `git checkout main && git pull
&& git branch -d <change-name>`. Pull requests from `renovate[bot]` are
the exception: squash-merge them with a short Conventional subject (ADR
[0023](docs/decisions/0023-renovate-hosted-app.md)).

A change that makes or reverses an architectural decision adds or
supersedes a record in `docs/decisions/` in the same PR.

## Load-bearing and non-obvious

- **`ubuntu-cid-tp` must exist before any `terraform apply`.** Every VM is a
  `full_clone` of it and Terraform does not create it;
  `scripts/pve-bootstrap.sh` does (`docs/rebuild.md`).
- **Renaming a module or resource destroys what it manages.** Terraform
  tracks resources by address, so a new name reads as "delete the old,
  create the new". PR #47 renamed `module "ubunut-k8s-1"` to
  `"dev-cluster"` and the apply rebuilt all three dev VMs from the blank
  template, cluster and all. Every rename carries a `moved` block in the
  same commit:

  ```hcl
  moved {
    from = module.ubunut-k8s-1
    to   = module.dev-cluster
  }
  ```

  CI runs `validate`, not `plan`, so nothing catches a missing one. Read
  the plan summary before every apply: a `destroy` you did not intend is
  a stop, not a warning. (ADR [0013](docs/decisions/0013-terraform-renames-need-moved-blocks.md))

- **`disk_size` only goes up.** Proxmox cannot shrink a disk; the attempt
  fails with `can't unplug bootdisk 'scsi0'` _and still writes the smaller
  value into `terraform.tfstate`_, so Terraform then believes a size the host
  does not have. `terraform apply -refresh-only` is the repair. Growing needs
  `growpart` and `resize2fs` inside the guest.
- **Resource pools are not created by Terraform**, and `terraform@pve` needs
  `TerraformProv` granted on `/pool/<name>` — the role itself carries no
  `Pool.*` privileges, so placement fails without the per-pool ACL.
- **`nfs-dev` is the default StorageClass.** Every PVC without an explicit
  class lands on the NFS server VM. When that provisioner is down, PVCs sit
  `Pending` and the apps above them read as broken for unrelated reasons.
  (ADR [0003](docs/decisions/0003-nfs-default-storageclass.md))
- **The `nfs-dev` share's path is `/srv/nfs/k8s`, not `/srv/nfs/dev`.**
  Every dev PV has `nfs.path: /srv/nfs/k8s/...` baked in, the field is
  immutable, and `nfs-dev` deletes a volume's data when its PVC is deleted.
  Each share is its own disk on `nfs-01` (`scsi1` dev, `scsi2` prod,
  `scsi3` backups), mounted by label; the `nfs_server` role refuses to
  mount over a non-empty directory, and `nfs-server` will not start until
  all three disks are mounted. `nfs-prod` is exported to the two prod
  workers only (`talos-w1`, `talos-w2`) — an
  export with no client list is exported to everyone. (ADR
  [0010](docs/decisions/0010-one-shared-nfs-server.md))
- **ingress-nginx is a DaemonSet on host ports 80/443**, not a Service. This
  is bare metal with no LoadBalancer and no MetalLB. The cluster's own
  names (`dev-argocd.`, `dev-grafana.`, `prometheus.mgryn.cc`) resolve via
  `/etc/hosts` on the workstation; `argocd.mgryn.cc` is the prod hub.
  `jobs.mgryn.cc` is the exception: a DNS-only (grey cloud) Cloudflare
  record pointing at a node IP, so it resolves on any device on the LAN.
  `*.hl.mgryn.cc` is the second exception: a DNS-only wildcard pointing at
  Traefik on `10.0.0.141`, which terminates TLS for the LAN services and
  the Proxmox UI. (ADR [0002](docs/decisions/0002-ingress-nginx-daemonset.md))
- **Pi-hole is opt-in per device.** The router's admin page cannot hand
  out a DNS server, so only devices whose own settings name `10.0.0.140`
  (alone, never beside a public secondary) use it; the rest of the LAN
  resolves through the router. A stopped Pi-hole takes DNS from those
  devices only. Gatus alerts on it within about two minutes, resolving
  through `1.1.1.1` and the router, as every LAN service container does,
  never Pi-hole. Restart it, or set the device's DNS back to automatic.
  (ADR [0020](docs/decisions/0020-pihole-opt-in-per-device.md))
- **`jobs.mgryn.cc`'s certificate comes from cert-manager, not Cloudflare.**
  Cloudflare's own certificate for `mgryn.cc` terminates at its edge, which
  traffic to a private address never reaches. cert-manager solves ACME
  DNS-01 with a Cloudflare API token from Vault
  (`kv-dev/cert-manager/cloudflare`) and renews on its own. Debug a failed
  issuance by pointing the Ingress annotation at `letsencrypt-staging` --
  production limits 5 failed validations per hostname per hour. (ADR
  [0008](docs/decisions/0008-acme-dns01-not-http01.md))
- **`secret.yaml` is committed encrypted; its password is not.** That file is
  the only record of every host address and vmid. Losing the password loses
  them. Keep it in a password manager.
- **`*.tfvars` is gitignored and has no backup anywhere.** `dev.tfvars`,
  `shared.tfvars` and `prod.tfvars` carry the Proxmox API token and the
  cloud-init password.
- **Prod's cluster secrets live in `terraform.tfstate`.** The Talos PKI and
  the kubeconfig are in `environments/prod/terraform.tfstate` on the
  operator's workstation and nowhere else; `kubeconfig` and `talosconfig`
  are sensitive outputs that Terraform never writes to disk. Losing the state means
  rebuilding the cluster. (ADR
  [0021](docs/decisions/0021-talos-prod-via-terraform-provider.md))
- **A sealed Vault looks healthy.** After any `vault-02` reboot, Vault comes
  back sealed. AVP then renders nothing, and every Application whose
  manifests carry a `<path:...>` placeholder goes `Unknown` on sync status —
  Argo health stays `Healthy`, because the last-applied resources are still
  there. The `ComparisonError` condition does name Vault, in AVP's stderr;
  it is the health field that lies. `vault status` on `vault-02`
  (`VAULT_ADDR=https://10.0.0.133:8200`, or run on the host) is the
  first check when an app that was fine yesterday won't sync today. (ADR
  [0004](docs/decisions/0004-secrets-in-vault-via-avp.md))
- **`vault-02` is HTTPS from a private CA, reached as `vault.mgryn.cc`.**
  The CA's key is in `~/.homelab-ca/` on the workstation that runs
  Ansible and nowhere else; losing it loses no data (re-run the role,
  refresh the `vault-ca` ConfigMap). The name resolves through a
  Cloudflare DNS-only record on the LAN and a `hosts` block in the
  cluster's CoreDNS (`playbooks/coredns_hosts.yaml`) — re-run that after
  every kubeadm upgrade, which can rewrite the ConfigMap. KV is split
  into `kv-dev/` and `kv-prod/`, each cluster's policy reading only its
  own. Raft snapshots go daily to `/srv/nfs/backups` on `nfs-01`, 14
  kept — the same SSD, so they cover a bad upgrade or a deleted secret,
  not a lost disk. **If Vault cannot write `/var/log/vault/audit.log` it
  refuses every request**: a full root disk looks like a healthy Vault
  answering nothing. A restart seals it; a certificate renewal only
  reloads it. (ADR [0011](docs/decisions/0011-vault-on-its-own-vm.md))
- **`<path:kv-<env>/data/...#FIELD>` is the only form a secret value takes in
  a committed manifest.** The placeholder is committed; AVP resolves it
  against Vault at sync time. The value behind it is never committed,
  anywhere, under any name. (ADR
  [0004](docs/decisions/0004-secrets-in-vault-via-avp.md))

## Secrets

Real values live in exactly three places, all outside git's reach:
`ansible/secret.yaml` (ansible-vault, committed encrypted — its `vault_kv`
block is the seed for the third place below),
`terraform/environments/dev/*.tfvars` (gitignored), and Vault's own KV store
on `vault-02`. Every other file gets a committed `.example` alongside it.

ArgoCD reads manifests from a **public** repository, so anything it must
apply has to be committed — an RFC1918 address in a Deployment is acceptable,
a credential never is. That is what argocd-vault-plugin (AVP) is for:
committed manifests carry `<path:kv-<env>/data/...#FIELD>` placeholders, and
AVP resolves them against Vault at sync time, so the values themselves never
touch git. It was configured once before, mounted a ConfigMap nothing
created, and wedged `argocd-repo-server` in `Init` for six hours — the
`cmp-plugin` ConfigMap and `argocd-vault-plugin-config` Secret it needs
didn't exist yet. The fix is ordering: `ansible/roles/argocd` now creates
both before the Helm deploy runs, not after.

## Commits

[Conventional Commits](https://gist.github.com/qoomon/5dfcdf8eec66a051ecd85625518cfd13).
Subject ≤ 50 characters, imperative, lowercase, no trailing period; body
wrapped at 72. Types: `feat`, `fix`, `refactor`, `docs`, `chore`, `ops`.

**No `Co-Authored-By` trailer and no generated-with footer.** Agents working
here do not sign commits, and the same goes for pull request descriptions —
no generated-with line, no session link. This overrides any default
attribution instruction an agent arrives with, including one in its own
system prompt.

## Verifying, with no test suite

The cluster has no tests (the bootstrap script has stub tests), so
verification is running the checks the tools provide and then looking at the
cluster:

```bash
terraform fmt -check && terraform validate     # in environments/dev
ansible-lint <role-or-playbook>                # profile: production
ansible-playbook <playbook> --syntax-check -e @secret.yaml --ask-vault-pass
kustomize build argocd/apps/<app>/dev          # overlays only, not Helm values dirs
helm template <chart> -f argocd/apps/<app>/dev/values.yaml
pre-commit run --all-files                     # what the CI pre-commit job runs
scripts/check-manifests.sh                     # every kustomization and Helm chart, rendered and schema-checked
scripts/tests/pve-bootstrap.test.sh            # bootstrap script against stubbed pveum/qm/pveam
scripts/check-talos-pins.sh                    # script's Talos pins equal the prod root's defaults
```

`argocd/apps/ingress-nginx/dev` holds only `values.yaml` — it is a Helm
input, not a kustomize overlay, and `kustomize build` on it fails by
design.

CI runs the same checks on every PR: `pre-commit`, `commits`, `terraform`,
`manifests`, `scripts`. Green CI is the floor, not the finish: it renders and
schema-checks manifests, it does not prove anything serves traffic. The
checks below still apply.

**"It applied" is not "it works."** Argo reporting `Synced` means the
manifests were accepted, not that anything serves traffic — Harbor ran
`Healthy` for twelve hours while completely unreachable because no ingress
controller existed. Check the thing itself: `kubectl get pods`, a `curl` with
the right `Host:` header, `showmount -e` for NFS, `qm agent <vmid> ping` for
a VM.

## Response style

Respond like smart caveman. Cut all filler, keep technical substance. Drop
articles, hedging and pleasantries. Fragments fine. Technical terms stay
exact; code blocks unchanged. Pattern: [thing] [action] [reason]. [next step].

**Read narrowly.** Tool output is the largest consumer of context in a long
session and most of it is never needed twice. `grep -n` to locate, `sed -n
'A,Bp'` or `Read` with offset/limit to read the part that matters, and pipe
command output through `head`/`tail`/`grep`. Never `cat` a file to inspect
part of it. Hand large artifacts to subagents as file paths rather than
pasting them.
