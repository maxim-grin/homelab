# Operations

Day-to-day operations: how a change is applied, where each UI lives, how to ship a jobboard version, and what to
check when a certificate will not issue. Rebuilding from nothing is [rebuild.md](rebuild.md).

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

| Name                                                                                             | What                                                                                                | TLS          |
| ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- | ------------ |
| `https://jobs.mgryn.cc`                                                                          | jobboard; HTTP 308s to HTTPS                                                                        | cert-manager |
| `http://argocd.mgryn.cc`                                                                         | ArgoCD UI                                                                                           | none         |
| `https://grafana.mgryn.cc`                                                                       | Grafana; HTTP 308s to HTTPS                                                                         | cert-manager |
| `http://prometheus.mgryn.cc`                                                                     | Prometheus, no authentication — Prometheus ships none                                               | none         |
| `https://vault.mgryn.cc:8200`                                                                    | Vault UI, straight to `vault-02`, not through ingress-nginx, so reachable while the cluster is down | private CA   |
| `https://pihole.hl.mgryn.cc`, `proxmox.hl.mgryn.cc`, `traefik.hl.mgryn.cc`, `status.hl.mgryn.cc`, `lan.hl.mgryn.cc` | Pi-hole, the Proxmox UI, Traefik's dashboard, Gatus, LAN Orangutan                                               | Traefik      |

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

## Updating a pinned version

Renovate opens a pull request weekly (Mondays before 07:00 UTC, three
at most). Pins with no companion hash open on their own. Pins with one — the
four CI tools with a hash (`gitleaks`, `kustomize`, `kubeconform`,
`yq`), `gatus`, `orangutan` (and `glance` once PR #65 lands) — wait:
tick the box in the **Dependency Dashboard** issue to open the PR, then
push the new hash to its branch. `traefik` is gated too but needs
nothing pushed: tick, then merge once CI is green.

Once you push a hash commit to a Renovate branch, Renovate treats it as
edited: it will not rebase it or bump it to a newer patch, and the
"rebase" checkbox would discard your hash. To take a newer version,
close the PR and tick the dashboard box again.

Skipping the hash fails loudly: CI stops at `sha256sum --strict` for
the tools, and the Ansible run stops at the download for the roles.

Squash-merge a Renovate PR with a short Conventional subject
(`chore: bump gitleaks to 8.31.0`); other PRs keep merge commits. A
merge is still a deploy for the Helm chart pins in the Application CRs
and for the jobboard image in `argocd/apps/jobboard/dev/kustomization.yaml`.

| Pin                                                  | Where the hash lives                                                                                                                                 | Command                                                                                                               |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| CI tools (`gitleaks`, `kustomize`, `kubeconform`, `yq`) | `*_SHA256` in the `env` block of `.github/workflows/ci.yaml`                                                                                      | `gh api repos/<owner>/<repo>/releases/tags/<tag> --jq '.assets[] \| select(.name=="<asset>") \| .digest'`; asset names are in the workflow's install steps |
| `orangutan` (`glance` after #65: `glance_archive_sha256` in `ansible/roles/glance/defaults/main.yaml`) | `orangutan_deb_sha256` in `ansible/roles/orangutan/defaults/main.yaml`                                                                              | the same `gh api` command; it is also in that file's comment                                                          |
| `gatus`                                              | `gatus_layer_digest` in `ansible/roles/gatus/defaults/main.yaml`                                                                                    | the `curl` and `jq` steps in the comment at the top of that file; a registry layer digest, not a release asset        |
| `traefik`                                            | Traefik's published checksums file, read by the role                                                                                                | nothing to push                                                                                                       |
| Actions, providers, Helm charts, `pre-commit`, `ansible-lint`, `terraform`, `tflint`, `helm` | none                                                                                                                | none                                                                                                                  |

Each pin's own comment and ADR
[0017](decisions/0017-verify-lan-service-binaries-sha256.md) hold the
detail; the commands are not copied beyond this table.

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
