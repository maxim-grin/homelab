# Vault + argocd-vault-plugin design

Date: 2026-09-10
Status: approved, not yet implemented
Environment: `dev` only

## Problem

Two Kubernetes Secrets are created by hand at every rebuild --
`jobboard-secrets` and the `ghcr` pull secret (`docs/rebuild.md` steps 10-11).
`argocd/base/projects.yaml` is applied by hand every time a Helm repository is
added to `sourceRepos`. `ghcr.io/maxim-grin/jobboard:latest` moves without the
Deployment spec changing, so ArgoCD sees no diff and nothing restarts; the
documented workaround is a manual `kubectl rollout restart`.

An earlier attempt at argocd-vault-plugin (AVP) wedged `argocd-repo-server` in
`Init` for six hours and was removed deliberately. The cause is recorded in
`ansible/roles/argocd/defaults/main.yaml`: the Helm values referenced a
`cmp-plugin` ConfigMap and an `argocd-vault-plugin-config` Secret that nothing
in this repository ever created, so kubelet looped on
`MountVolume.SetUp failed for volume "cmp-plugin": configmap not found`.

## Decisions

| Decision | Chosen | Rejected |
| --- | --- | --- |
| Where Vault runs | Proxmox VM, `modules/ubuntu-vm` | In-cluster Helm; LXC |
| Secret delivery | argocd-vault-plugin | External Secrets Operator |
| Seed storage | `vault_kv` block in `ansible/secret.yaml` | A SOPS-encrypted `vault/secrets.yaml.enc` |
| Unseal | `-key-shares=1 -key-threshold=1`, manual | 3-of-5 Shamir; auto-unseal from local key file |
| `vault.mgryn.cc` | `/etc/hosts` straight to the VM, port 8200 | Cluster ingress via a selector-less Service |
| Image write-back | git, with a PAT from Vault | ArgoCD annotation write-back |

Rationale for the two non-obvious ones:

**Vault outside the cluster.** Vault holds the secrets a cluster rebuild
consumes. In-cluster Vault dies with the cluster and cannot serve its own
recovery. The same argument sends `vault.mgryn.cc` straight to the VM: routing
it through `ingress-nginx` makes the URL unavailable in exactly the situation
it exists for.

**No SOPS.** The repository already has an encrypted-and-committed secret
store whose password is typed on every playbook run. A second encryption
system means a second key that is fatal to lose, protecting data of the same
sensitivity as the first. `ansible/secret.yaml` already carries that risk and
`docs/rebuild.md` already documents it.

## Survival model

Vault is **reconstructible, not backed up**. Nothing snapshots
`/opt/vault/data`; it is disposable.

| Tier | Survives cluster rebuild | Survives Proxmox loss |
| --- | --- | --- |
| `vault-01` VM, `/opt/vault/data` | yes | no |
| `ansible/secret.yaml` (`vault_kv`), pushed to GitHub | yes | yes |
| Password manager: ansible-vault password, unseal key, root token | yes | yes |

Rebuild path: rebuild host -> `terraform apply` -> `ansible-playbook
playbooks/vault.yaml` -> `vault operator init -key-shares=1 -key-threshold=1`
(a **new** unseal key, recorded in the password manager) -> seed task replays
every KV path from `vault_kv`.

The unseal key and root token are never written to `secret.yaml`, never
defaulted in a role, and never captured by a playbook. Tasks needing the root
token take it per-run: `-e vault_token=...`.

## Architecture

```txt
workstation /etc/hosts
  argocd.mgryn.cc -> any node IP    -> ingress-nginx -> argocd-server
  vault.mgryn.cc  -> vault-01 IP    -> :8200 directly, no cluster

vault-01 (Proxmox VM, outside the cluster)
  Vault, file storage, tls_disable, disable_mlock, single unseal key
  KV v2 at secret/, kubernetes auth method
       ^
       | k8s auth as SA argocd-repo-server, role "argocd", policy argocd-read
       |
argocd namespace
  argocd-repo-server
    initContainer download-tools -> emptyDir custom-tools (avp binary)
    sidecar avp -> argocd-cmp-server
    ConfigMap cmp-plugin  (avp.yaml)          <- created by Ansible FIRST
    Secret argocd-vault-plugin-config         <- created by Ansible FIRST
  argocd-image-updater -> ghcr.io -> git commit -> ArgoCD sync
```

## Layer 1 -- Terraform

`proxmox/environments/dev/main.tf` gains a `vault` module beside `nfs` and
`claude_code`, using `modules/ubuntu-vm`, a full clone of `ubuntu-cid-tp` like
every other machine. `dev.tfvars` gains its vmid and address.

`disk_size` only goes up. Size the disk generously at creation; Vault's file
backend is small, so the default is ample.

## Layer 2 -- Ansible

**`ansible/playbooks/vault_setup.yaml` is replaced, not moved.** It is bare
tasks in a playbook while the repository's convention is `roles/` plus thin
playbooks, and it will not pass `ansible-lint` at the production profile: no
FQCNs, `become: yes` rather than `true`, and `shell` with `wget` to install the
GPG key. It becomes:

- `ansible/roles/vault/` -- install from the HashiCorp apt repository, render
  `/etc/vault.d/vault.hcl` (file storage at `/opt/vault/data`,
  `tls_disable = 1`, `disable_mlock = true`, `ui = true`), enable the systemd
  unit. Config content carries over unchanged from the old playbook.
- `ansible/roles/vault/tasks/configure.yaml` -- KV v2 at `secret/`, the
  `kubernetes` auth method, policy `argocd-read`, role `argocd` bound to
  ServiceAccount `argocd-repo-server` in namespace `argocd`. Requires
  `vault_token`; fails fast with a clear message when it is undefined.
- `ansible/roles/vault/tasks/seed.yaml` -- idempotent `vault kv put` for every
  entry in `vault_kv`. Requires `vault_token`.
- `ansible/playbooks/vault.yaml` -- applies the role to the `vault` group.

`ansible/inventories/dev/hosts.yaml` gains a `vault` group with `vault-01`,
matching the group `vault_setup.yaml` already targeted but which existed only
in `inventories/prod/`.

`ansible/secret.yaml` gains `host_ips['vault-01']`, `proxmox_vm_ids['vault-01']`
and a `vault_kv` block. `ansible/secret.yaml.example` is updated to match, with
fake values.

```yaml
vault_kv:
  jobboard/db:
    username: ...
    password: ...
  jobboard/ghcr:
    token: ...
  argocd/git:
    pat: ...        # image-updater git write-back
```

## Layer 3 -- ArgoCD and AVP

**Task order in `ansible/roles/argocd/tasks/main.yaml` is the entire fix.** Two
`kubernetes.core.k8s` tasks are inserted *before* the existing Helm deploy, so
both volumes exist when repo-server first starts:

1. ConfigMap `cmp-plugin` in `argocd`, holding `avp.yaml`, the
   `ConfigManagementPlugin` spec. **This is the object whose absence caused the
   original failure.**
2. Secret `argocd-vault-plugin-config`: `AVP_TYPE=vault`, `AVP_AUTH_TYPE=k8s`,
   `AVP_K8S_ROLE=argocd`, `VAULT_ADDR=http://<vault-01 IP>:8200`. Under
   Kubernetes auth this Secret holds no credential.

`argocd_helm_values` in `ansible/roles/argocd/defaults/main.yaml` stops being
`{}` and gains a `repoServer` block: a `download-tools` initContainer fetching
the `argocd-vault-plugin` binary into a `custom-tools` emptyDir, and an `avp`
sidecar running `argocd-cmp-server` with both volumes mounted.

The existing comment above `argocd_helm_values` is **rewritten, not deleted**.
It records why repo-server wedged; the replacement records that all four
objects now exist and that Ansible task order is what guarantees it.

Manifests then carry placeholders. `argocd/apps/jobboard/base/secret.yaml`
becomes a committed manifest holding
`<path:secret/data/jobboard/db#password>` rather than a value -- the first
`<path:...>` in this repository -- and its `.gitignore` entry and
`secret.yaml.example` are removed. Same for the `ghcr` pull secret. The
jobboard Application gains the `argocd.argoproj.io/plugin-name` annotation so
repo-server routes it through the sidecar. `docs/rebuild.md` steps 10-11 are
deleted.

## Layer 4 -- projects.yaml self-management

New `argocd/environments/dev/applications/argocd-config.yaml`, an Application
pointing at `argocd/base/`, picked up by `root-dev` like any other file there.

- `prune: false` -- a prune that removes the AppProject orphans every
  application in the cluster at once.
- `selfHeal: true` -- a hand-edited project snaps back.

This removes the *recurring* manual apply, not the bootstrap one. At rebuild
the AppProject must still be applied by hand once, because `root-dev` is itself
`project: homelab` and cannot sync until the project authorising it exists.
That step stays in `docs/rebuild.md`.

## Layer 5 -- Ingress

`argocd.mgryn.cc` is configured through `argocd_helm_values`:
`server.ingress.enabled`, the hostname, `ingressClassName: nginx`, and
`server.insecure: true` so nginx speaks plain HTTP to argocd-server rather than
TLS to TLS. No TLS, matching `harbor.mgryn.cc` and `jobs.mgryn.cc`.
`argocd_nodeport_enabled` stays `false`.

Two `/etc/hosts` lines on the workstation: `argocd.mgryn.cc` at any node IP,
`vault.mgryn.cc` at `vault-01`. Vault's UI is `http://vault.mgryn.cc:8200`.

## Layer 6 -- Image updater

`argocd-image-updater` is delivered as an ArgoCD Application using the
`argocd-image-updater` chart from `https://argoproj.github.io/argo-helm`, with
its values under
`argocd/apps/image-updater/dev/values.yaml` -- a Helm inputs directory like
`harbor` and `ingress-nginx`, so `kustomize build` on it fails by design. The
`https://argoproj.github.io/argo-helm` repository must be added to the
AppProject's `sourceRepos`, which by then is self-managing.

It runs with `update-strategy: digest` on the `latest` tag: it tracks the
digest behind the mutable tag, which is the exact failure mode today. Registry credentials come
from `secret/jobboard/ghcr` via AVP.

Write-back is `git`. The new digest is committed to this repository and ArgoCD
syncs the commit normally, so git continues to describe what is deployed. The
GitHub PAT lives at `secret/argocd/git` and reaches the cluster through AVP, so
it costs no manual step -- but it is a write credential for a public
repository and its blast radius is the whole repository. The
`README.md` note about the manual `kubectl rollout restart` is removed.

## Verification

No test suite. Verification is tool checks plus looking at the cluster.

```bash
# Layer 1
terraform fmt -check && terraform validate          # in environments/dev
qm agent <vault vmid> ping

# Layer 2
ansible-lint roles/vault playbooks/vault.yaml
ansible-playbook playbooks/vault.yaml --syntax-check -e @secret.yaml --ask-vault-pass
vault status                                        # on vault-01: Sealed false

# Layer 3 -- the object that mattered
kubectl -n argocd get configmap cmp-plugin
kubectl -n argocd get pods                          # repo-server 2/2, NOT Init
kubectl -n argocd logs deploy/argocd-repo-server -c avp

# Layer 3 -- the payoff
kubectl -n jobboard get secret jobboard-secrets \
  -o jsonpath='{.data.password}' | base64 -d        # matches Vault
kubectl -n jobboard get pods                        # Running, not CreateContainerConfigError

# Layers 4-6
kubectl -n argocd get appproject homelab -o yaml    # reflects git after a push
curl -H 'Host: argocd.mgryn.cc' http://<node IP>/
kubectl -n argocd logs deploy/argocd-image-updater
kustomize build argocd/apps/jobboard/dev                # overlay still renders
helm template argocd-image-updater -f argocd/apps/image-updater/dev/values.yaml
```

"Synced" is not "works". Harbor reported `Healthy` for twelve hours while
unreachable. Every layer above is checked against the thing itself.

## Sharp edges

1. **Kubernetes auth from outside the cluster.** Vault cannot use the local
   ServiceAccount shortcut. It needs `disable_local_ca_jwt=true`, the cluster
   CA certificate, and a long-lived `token_reviewer_jwt` from a dedicated
   ServiceAccount bound to `system:auth-delegator`. This is the fiddliest part
   of the design and the likeliest source of an opaque `permission denied`
   from Vault. The fallback, if it proves unworkable, is a static Vault token
   in `argocd-vault-plugin-config` -- simpler, but a real credential recreated
   by hand at every rebuild, which is the problem AVP exists to remove.
2. **Sealed Vault is a silent failure.** After any reboot of `vault-01`, Vault
   is sealed, AVP renders nothing, and Applications degrade for a reason that
   does not mention Vault. `docs/rebuild.md` gets a prominent note; unsealing
   is the first thing to check when secrets stop resolving.
3. **Ordering at rebuild.** Vault must be running, unsealed and seeded before
   ArgoCD syncs anything that carries a `<path:...>` placeholder.
   `docs/rebuild.md` sequencing must place the Vault playbook before the
   ArgoCD bootstrap.
4. **A third system holding secrets.** `ansible/secret.yaml`, `*.tfvars`, and
   now Vault. Vault's seed nests inside the first, which bounds the sprawl but
   does not eliminate it.

## Out of scope

- Migrating `*.tfvars` or `ansible/secret.yaml` onto SOPS or into Vault.
- `proxmox/README.md` documents a SOPS workflow with `dev.tfvars.enc` and
  `backend.tf.enc`; no `.enc` file is committed anywhere and there is no
  `.sops.yaml`. CLAUDE.md contradicts it directly. Left alone here because
  this design no longer introduces SOPS, but it remains wrong.
- TLS anywhere. Vault runs `tls_disable = 1` and ingress is plain HTTP,
  consistent with the rest of the homelab.
- `proxmox/environments/prod` and `talos/`, which have never been applied.
  `inventories/prod/hosts.yaml` already declares a `vault-lxc` host; it stays
  untouched scaffolding.
- A GitHub webhook for faster syncing. It needs `argocd-server` reachable from
  GitHub, which this homelab is not.
