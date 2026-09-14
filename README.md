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
| Storage    | NFS server VM exporting `/srv/nfs/k8s`, `nfs-dev` StorageClass | `ansible/roles/nfs_server`, `argocd/apps/nfs_provisioner` |
| Apps       | gitea, harbor, monitoring (Prometheus + Grafana), jobboard      | `argocd/apps/`                                            |
| Secrets    | Vault (`vault.mgryn.cc:8200`), LXC `vault-01`; argocd-vault-plugin resolves `<path:...>` placeholders at sync time | `ansible/roles/vault`, `proxmox/environments/dev` |

Hostnames resolve through `/etc/hosts` on the workstation. Most point at a
node IP, since ingress-nginx answers on every node; `vault.mgryn.cc` is the
exception and points straight at `vault-01`. There is no Pi-hole, no
Traefik and no Cloudflare Tunnel yet.

## jobboard image tag

`argocd/apps/jobboard/base/app-deployment.yaml` pins
`ghcr.io/maxim-grin/jobboard:latest`, not a SHA. A push to the app repo's
`main` publishes a new image but changes no manifest here, so ArgoCD sees
no diff and never redeploys — the running pod keeps the old image until
someone restarts it by hand:

```
kubectl rollout restart deployment/jobboard -n jobboard
```

This is deliberate, not an oversight: `:latest` is a mutable tag, so the
Deployment's pod spec never changes and Kubernetes sees nothing to roll.

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

Nine hooks: file hygiene, `check-yaml`, `detect-private-key`, `gitleaks`,
`ansible-lint`, `terraform fmt`, and a conventional-commit check on the
message. `ansible/.ansible-lint-ignore` holds the 26 findings inherited from
the repository this was copied from — they stay visible rather than silenced,
and anything new fails.

## Day-to-day

```bash
# provision or change VMs
cd proxmox/environments/dev
terraform apply -var-file=dev.tfvars

# configure them
cd ansible
ansible-playbook playbooks/site.yaml -e @secret.yaml --ask-vault-pass

# applications deploy themselves: ArgoCD syncs main from GitHub, so a change
# is live once it is pushed, not once it is committed
git push origin main
```

ArgoCD UI: `http://argocd.mgryn.cc`
Gitea: `http://gitea.mgryn.cc` · Grafana: `http://grafana.mgryn.cc`
Prometheus: `http://prometheus.mgryn.cc` (no authentication -- Prometheus ships none)
Vault UI: `http://vault.mgryn.cc:8200` -- straight to `vault-01`, not through
ingress-nginx, so it is reachable even when the cluster is down

See `ansible/README.md` and `proxmox/README.md` for the detail of each half.
