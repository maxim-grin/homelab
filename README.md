# homelab

Bare-metal Proxmox homelab: VMs provisioned with Terraform, configured with
Ansible, and applications delivered to Kubernetes by ArgoCD.

Everything here describes one physical machine and the `dev` environment on it. There is no
second host and no `prod` cluster; the `prod/` directories are scaffolding not yet implemented.

**If you are rebuilding after a disk replacement or a total loss, start at
[docs/rebuild.md](docs/rebuild.md).** It lists what this repository does
_not_ contain, which is the part that will bite.

## What actually runs

| Layer      | What                                                           | Where it is defined                                       |
| ---------- | -------------------------------------------------------------- | --------------------------------------------------------- |
| Hypervisor | Proxmox VE, node `pve`                                         | not in git — see `docs/rebuild.md`                        |
| VMs        | ubuntu, ubuntu-2, k8s master + 2 workers, workstation, nfs     | `proxmox/environments/dev`                                |
| OS config  | kubeadm cluster, containerd, NFS server and client             | `ansible/`                                                |
| GitOps     | ArgoCD (`argocd.mgryn.cc`), app-of-apps `root-dev`              | `ansible/roles/argocd`, `argocd/environments/dev`         |
| Ingress    | ingress-nginx, DaemonSet on host ports 80/443                  | `argocd/apps/ingress-nginx`                               |
| TLS        | cert-manager, Let's Encrypt via ACME DNS-01 through Cloudflare | `argocd/apps/cert-manager`, `argocd/apps/cert-manager-issuers` |
| Storage    | NFS server VM exporting `/srv/nfs/k8s`, `nfs-dev` StorageClass | `ansible/roles/nfs_server`, `argocd/apps/nfs_provisioner` |
| Apps       | gitea, harbor, monitoring (Prometheus + Grafana), jobboard      | `argocd/apps/`                                            |
| Secrets    | Vault (`vault.mgryn.cc:8200`), LXC `vault-01`; argocd-vault-plugin resolves `<path:...>` placeholders at sync time | `ansible/roles/vault`, `proxmox/environments/dev` |

Most hostnames resolve through `/etc/hosts` on the workstation, pointing at
a node IP since ingress-nginx answers on every node; `vault.mgryn.cc` is the
exception and points straight at `vault-01`. There is no Pi-hole, no Traefik
and no Cloudflare Tunnel.

`jobs.mgryn.cc` is the one name in public DNS: a DNS-only (grey cloud)
Cloudflare record holding a node IP, so any device on the LAN resolves it
without a hosts entry. Public DNS answering with a private address is fine,
though some routers drop it as DNS-rebinding protection. It is also the only
name served over HTTPS — see TLS, below.

## TLS

`jobs.mgryn.cc` is served over HTTPS with a Let's Encrypt certificate.
cert-manager obtains it with an ACME DNS-01 challenge, writing a TXT record
through the Cloudflare API with a token held in Vault at
`secret/cert-manager/cloudflare`. Renewal is automatic, 30 days before
expiry.

DNS-01 rather than HTTP-01 because nothing here is reachable from the public
internet, and DNS-01 proves domain control by writing a record rather than
by answering a request. Nothing is exposed to add TLS.

Cloudflare's own certificate for `mgryn.cc` cannot be used: it terminates at
Cloudflare's edge, and traffic to a private address never goes there.

Two issuers exist — `letsencrypt-prod` and `letsencrypt-staging`. If
issuance breaks, point the Ingress annotation at staging while debugging.
Staging certificates are untrusted, so the browser warns, but production
allows only 5 failed validations per hostname per hour and 50 certificates
per domain per week.

```bash
kubectl -n jobboard describe certificate jobboard-tls
kubectl -n jobboard get order,challenge
```

## jobboard image version

`argocd/apps/jobboard/dev/kustomization.yaml` names the published version to
run; `argocd/apps/jobboard/base/app-deployment.yaml` carries no tag. Deploying
a new build is one line:

```
newTag: "0.2.0"
```

commit, and merge it through a pull request. The pod spec genuinely changes,
so ArgoCD rolls it on the next poll — no `kubectl rollout restart`. Rolling
back is the same edit with the previous number, and it works, which it could
not when the tag was `:latest` and a revert changed nothing.

The app repository publishes `ghcr.io/maxim-grin/jobboard:<version>` only when
a `v<version>` git tag is pushed there. Naming a version here that has not been
published yet gives `ImagePullBackOff` until it is — loud and self-correcting.

## Layout

```txt
ansible/          Roles and playbooks. Inventory per environment, secrets in
                  an ansible-vault file. roles/vault/ installs and seeds
                  HashiCorp Vault.
argocd/           base/       AppProject
                  apps/       kustomize bases and dev overlays per app
                  environments/dev/applications/  Application CRs, synced by root-dev
proxmox/          modules/    reusable ubuntu-vm, ubuntu-k8s, lxc, talos-*
                  environments/dev/  the machines that exist
talos/            Unused. Templates for a Talos cluster that was never built.
scripts/          Ad-hoc checks.
docs/rebuild.md   How to recreate all of this from a bare Proxmox install.
```

## Checks before committing

```bash
# uv tool install takes one package per invocation, not a list
uv tool install pre-commit
uv tool install ansible-lint
pre-commit install                          # wires pre-commit AND commit-msg
```

The hooks: file hygiene, `check-yaml`, `detect-private-key`, `gitleaks`,
`ansible-lint`, `terraform fmt`, and a conventional-commit check on the
message. `ansible-lint` runs at profile `production` with no ignore file:
any finding fails. It needs the collections pinned in
`ansible/requirements.yml` (`ansible-galaxy collection install -r
ansible/requirements.yml`), and so do the playbooks themselves.

## Day-to-day

```bash
# provision or change VMs
cd proxmox/environments/dev
terraform apply -var-file=dev.tfvars

# configure them
cd ansible
ansible-playbook playbooks/site.yaml -e @secret.yaml --ask-vault-pass

# applications deploy themselves: ArgoCD syncs main from GitHub, so a change
# is live once its pull request merges, not once it is committed or pushed
git push -u origin <branch>
gh pr create --base main --fill
```

jobboard: `https://jobs.mgryn.cc` -- the only name with TLS; HTTP 308s to it
ArgoCD UI: `http://argocd.mgryn.cc`
Gitea: `http://gitea.mgryn.cc` · Grafana: `http://grafana.mgryn.cc`
Prometheus: `http://prometheus.mgryn.cc` (no authentication -- Prometheus ships none)
Vault UI: `http://vault.mgryn.cc:8200` -- straight to `vault-01`, not through
ingress-nginx, so it is reachable even when the cluster is down

See `ansible/README.md` and `proxmox/README.md` for the detail of each half.
