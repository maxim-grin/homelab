# Operations

Day-to-day detail moved out of the [README](../README.md): how a change is
applied, where each UI lives, how to ship a jobboard version, and what to
check when a certificate will not issue. Rebuilding from nothing is
[rebuild.md](rebuild.md); the checks and CI are [ci.md](ci.md).

## Applying a change

```bash
# provision or change VMs (dev cluster, claude-code)
cd terraform/environments/dev
terraform apply -var-file=dev.tfvars

# nfs-01, vault-02 and the LAN LXCs
cd terraform/environments/shared
terraform apply -var-file=shared.tfvars

# configure them
cd ansible
ansible-playbook playbooks/site.yaml -e @secret.yaml --ask-vault-pass

# applications deploy themselves: ArgoCD syncs main from GitHub, so a change
# is live once its pull request merges, not once it is committed or pushed
git push -u origin <branch>
gh pr create --base main --fill
```

Read the plan summary before every apply: a `destroy` you did not intend
is a stop — see
[ADR 0013](decisions/0013-terraform-renames-need-moved-blocks.md).

## Where things are

| Name | What | TLS |
| --- | --- | --- |
| `https://jobs.mgryn.cc` | jobboard; HTTP 308s to HTTPS | cert-manager |
| `http://argocd.mgryn.cc` | ArgoCD UI | none |
| `http://grafana.mgryn.cc` | Grafana | none |
| `http://prometheus.mgryn.cc` | Prometheus, no authentication — Prometheus ships none | none |
| `https://vault.mgryn.cc:8200` | Vault UI, straight to `vault-02`, not through ingress-nginx, so reachable while the cluster is down | private CA |
| `https://pihole.hl.mgryn.cc`, `proxmox.hl.mgryn.cc`, `traefik.hl.mgryn.cc`, `status.hl.mgryn.cc` | Pi-hole, the Proxmox UI, Traefik's dashboard, Gatus | Traefik |

The `*.mgryn.cc` names without `hl.` resolve through `/etc/hosts` on the
workstation, pointing at any node IP since ingress-nginx answers on every
node — except `jobs.mgryn.cc` and `vault.mgryn.cc`, which have DNS-only
Cloudflare records. `*.hl.mgryn.cc` is a DNS-only wildcard to `10.0.0.141`.

## jobboard image version

jobboard is the owner's own web application, deployed here with its
Postgres. Its source lives in a private repository; this one only
deploys the image, `ghcr.io/maxim-grin/jobboard`.

`argocd/apps/jobboard/dev/kustomization.yaml` names the published version to
run; `argocd/apps/jobboard/base/app-deployment.yaml` carries no tag.
Deploying a new build is one line:

```yaml
newTag: "0.2.0"
```

commit, and merge it through a pull request. The pod spec genuinely changes,
so ArgoCD rolls it on the next poll — no `kubectl rollout restart`. Rolling
back is the same edit with the previous number — see
[ADR 0007](decisions/0007-pin-image-tags-not-latest.md) for why that did
not use to work.

The app repository publishes `ghcr.io/maxim-grin/jobboard:<version>` only
when a `v<version>` git tag is pushed there. Naming a version here that has
not been published yet gives `ImagePullBackOff` until it is — loud and
self-correcting.

## When a certificate will not issue

Two cert-manager issuers exist — `letsencrypt-prod` and
`letsencrypt-staging`. If issuance breaks, point the Ingress annotation at
staging while debugging. Staging certificates are untrusted, so the browser
warns, but production allows only 5 failed validations per hostname per
hour and 50 certificates per domain per week.

```bash
kubectl -n jobboard describe certificate jobboard-tls
kubectl -n jobboard get order,challenge
```

Traefik's `*.hl.mgryn.cc` certificate is Traefik's own ACME client, not
cert-manager; debug it with `-e traefik_cert_resolver=letsencrypt-staging`
(see `ansible/roles/traefik/defaults/main.yaml`).
