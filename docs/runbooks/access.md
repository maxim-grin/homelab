# Access

Conventions (`$DEV_KC`, `$PROD_KC`, Vault address and token handling) are in
[README.md](README.md). Run from the operator's workstation. Nothing here
prints a kubeconfig, a `talosconfig` or a secret value: files are written
mode 600 and only their path is shown.

Sections: [Kubeconfigs](#kubeconfigs), [Names](#names), [UIs](#uis),
[Vault CLI](#vault-cli), [SSH](#ssh).

## Kubeconfigs

### Fetch the dev kubeconfig

When: first use on a workstation, or after a rebuild (a new cluster has a new
CA, so the old file no longer authenticates). `<master-01-ip>` is
`host_ips['master-01']` in `ansible/secret.yaml`
(`ansible-vault view secret.yaml`); the SSH user is `user_name` there and the
key is `~/.ssh/homelab_dev`.

```bash
KC_TMP="$(mktemp)"
ssh -i ~/.ssh/homelab_dev <user_name>@<master-01-ip> sudo cat /etc/kubernetes/admin.conf > "$KC_TMP"
kubectl --kubeconfig "$KC_TMP" get nodes
echo "kubeconfig is at $KC_TMP"
```

Expect: three nodes `Ready` (`ubuntu-k8s-master-01`, `worker-01`, `worker-02`). Point
`$DEV_KC` at the printed path while you work and `rm` the file afterwards.

If not: `Permission denied (publickey)` means the key is not the one
Terraform injected; a stale host key needs `ssh-keygen -R <master-01-ip>`.
`Unable to connect` or a certificate error: the file came from an older
cluster, fetch again.

### Fetch the prod kubeconfig

When: first use, or after any Terraform apply that rebuilt the Talos nodes.
The kubeconfig exists only as a sensitive Terraform output, read from
`terraform.tfstate` on the workstation that applied prod.

```bash
KC_TMP="$(mktemp)"
( cd "$(git rev-parse --show-toplevel)/terraform/environments/prod" && terraform output -raw kubeconfig ) > "$KC_TMP"
kubectl --kubeconfig "$KC_TMP" get nodes
echo "kubeconfig is at $KC_TMP"
```

Expect: `talos-prod-cp1`, `talos-prod-w1` and `talos-prod-w2` `Ready`. Point
`$PROD_KC` at the printed path and `rm` the file when done.

If not: right after an apply `No resources found` is normal for a few
minutes. An empty or failing `terraform output` means this is not the
workstation holding the state; without it the cluster cannot be reached
([backups-and-recovery.md](backups-and-recovery.md)).

### Fetch the talosconfig

When: you need `talosctl` (`health`, `services`, `reboot`). Talos has no SSH.
Same source as the prod kubeconfig.

```bash
TC_TMP="$(mktemp)"
( cd "$(git rev-parse --show-toplevel)/terraform/environments/prod" && terraform output -raw talosconfig ) > "$TC_TMP"
talosctl --talosconfig "$TC_TMP" -n 10.0.0.110 health
echo "talosconfig is at $TC_TMP"
```

Expect: `health` reports the checks passing for the node. `10.0.0.110` is
`talos-prod-cp1`; workers are `10.0.0.111` and `10.0.0.112`. `rm` the file when done.

If not: `talosctl -n <ip> services` shows what a node is waiting for, and
`qm terminal <vmid>` on `pve` shows its console.

## Names

Two kinds. The dev names have no public DNS and need `/etc/hosts` on the
workstation. The rest are DNS-only (grey cloud) Cloudflare records and
resolve on their own.

### Add the dev names to /etc/hosts

When: a dev UI does not resolve. ingress-nginx is a DaemonSet on host ports
80/443, so any dev node answers. `<dev-node-ip>` is `host_ips['worker-01']`
in `secret.yaml`. Prod's `argocd.mgryn.cc` and `grafana.mgryn.cc` are
Cloudflare records to the prod workers and need no entry. Delete any old
`grafana.mgryn.cc` line that points at a dev node.

```bash
sudo tee -a /etc/hosts >/dev/null <<'EOF'
<dev-node-ip> dev-grafana.mgryn.cc prometheus.mgryn.cc
EOF
getent hosts dev-grafana.mgryn.cc prometheus.mgryn.cc
```

Expect: each name prints the node address. Replace the placeholder before
running; the heredoc is written literally.

If not: Grafana renders absolute URLs from its configured root URL, so an
unresolved name shows as broken login redirects, not a connection error.

### Names that resolve without /etc/hosts

| Name                | Resolves to                                              | Behind                          |
| ------------------- | -------------------------------------------------------- | ------------------------------- |
| `jobs.mgryn.cc`     | a dev node IP (DNS-only A record)                        | ingress-nginx, cert-manager TLS |
| `argocd.mgryn.cc`   | `10.0.0.111` and `10.0.0.112` (two grey-cloud A records) | prod ingress-nginx              |
| `grafana.mgryn.cc`  | `10.0.0.111` and `10.0.0.112`                            | prod ingress-nginx              |
| `vault.mgryn.cc`    | `10.0.0.133` (`vault-02`)                                | Vault itself, port 8200, no ingress |
| `*.hl.mgryn.cc`     | `10.0.0.141` (DNS-only wildcard)                         | Traefik, one route per service  |

Pi-hole (`10.0.0.140`) is opt-in per device and not needed for any of
these ([ADR 0020](../decisions/0020-pihole-opt-in-per-device.md)).

## UIs

Login column names where the credential lives, never its value. `secret.yaml`
means `ansible/secret.yaml` (`ansible-vault view`); Vault paths are read with
[the pattern below](#vault-cli).

| UI                | URL                                      | Where the login comes from |
| ----------------- | ---------------------------------------- | -------------------------- |
| ArgoCD (prod hub) | `https://argocd.mgryn.cc`; break-glass `http://10.0.0.111:32080` (or `.112`, HTTPS `32443`) | user `admin`; password is not in Vault, its bcrypt hash is `argocd_admin_password_hash` in `secret.yaml` (the plaintext is yours) |
| Grafana (prod)    | `https://grafana.mgryn.cc`               | `kv-prod/monitoring/grafana`, fields `admin-user`, `admin-password` (only read when Grafana first creates its database) |
| Grafana (dev)     | `https://dev-grafana.mgryn.cc`           | `grafana_admin_password` in `secret.yaml`, kept in the `grafana-admin` Secret |
| Prometheus (dev)  | `http://prometheus.mgryn.cc`             | basic auth, `monitoring/prometheus` in `secret.yaml`'s `vault_kv` block, Vault `kv-dev/monitoring/prometheus` |
| Prometheus, Alertmanager (prod) | no UI Ingress; through Grafana, or `kubectl port-forward` ([operations.md](../operations.md)). The one Ingress is write-only: `https://prometheus.mgryn.cc/api/v1/write`, for dev's sender | basic auth, `kv-prod/monitoring/remote-write` (`htpasswd`; the plain pair is `kv-dev/monitoring/remote-write`) |
| jobboard          | `https://jobs.mgryn.cc`                  | app login; no infrastructure credential |
| Vault             | `https://vault.mgryn.cc:8200`            | root token from `vault operator init`, kept in the password manager; trust `~/.homelab-ca/ca.crt` |
| Pi-hole           | `https://pihole.hl.mgryn.cc` (opens `/admin/`) | `pihole_admin_password` in `secret.yaml` |
| Proxmox           | `https://proxmox.hl.mgryn.cc`            | the `<user>@pam` admin user from `scripts/pve-bootstrap.sh`; its password is yours |
| Traefik dashboard | `https://traefik.hl.mgryn.cc`            | `traefik_dashboard_users` in `secret.yaml` (htpasswd bcrypt lines) |
| Gatus             | `https://status.hl.mgryn.cc`             | `gatus_basic_user` and `gatus_basic_password` (bcrypt: `gatus_basic_password_bcrypt`) in `secret.yaml`; basic auth protects only Gatus's API (`/api/v1/...`), the root page loads without it |
| Glance            | `https://home.hl.mgryn.cc`               | no login configured in the role; its env file reads `pihole_app_password`, `glance_proxmox_token_id`, `glance_proxmox_token_secret`, `gatus_basic_user` and `gatus_basic_password` from `secret.yaml` |
| LAN Orangutan     | `https://lan.hl.mgryn.cc`                | `orangutan_password` in `secret.yaml` |

### Log in to the ArgoCD CLI

When: running `argocd app ...`, `argocd appset generate` or `argocd app
terminate-op` against the prod hub. The session token expires; a command that
fails with `Unauthenticated ... token is expired` needs a fresh login, nothing
more. `--grpc-web` is needed because ArgoCD sits behind ingress-nginx. The
password is the plaintext behind `argocd_admin_password_hash` (yours; see the
table above).

```bash
argocd login argocd.mgryn.cc --grpc-web --username admin
argocd app list --grpc-web | head -3
```

Expect: `'admin:login' logged in successfully`, then the Application list.

If not: a `504` means `argocd-server`, or what it waits on, is not answering:
`kubectl --kubeconfig "$PROD_KC" -n argocd get pods`, and check that
`argocd-application-controller-0` is `1/1` (a controller left at 0 replicas
makes refreshes hang). `argocd app get prod-kube-prometheus-stack` is slow because the chart
has about 90,000 lines of manifests; read what you need with `kubectl -n argocd
get app <name> -o jsonpath=...` instead. `--core` skips the login but talks to
whatever cluster and namespace your current kubectl context names, so it hangs
on the wrong context.

## Vault CLI

### Read a Vault field without leaking it

When: a table row above says a login is in Vault. The token is read with no
echo, never typed on the command line, and unset at the end. The command
prints the field to the terminal only; do not redirect it into a file or
history.

```bash
export VAULT_ADDR=https://10.0.0.133:8200
export VAULT_CACERT=~/.homelab-ca/ca.crt   # not needed on vault-02 itself
printf 'Vault token: '; read -rs VAULT_TOKEN; echo; export VAULT_TOKEN
vault kv get -field=admin-user kv-prod/monitoring/grafana
unset VAULT_TOKEN
```

Expect: the field prints on its own line. Swap the path and field. To only
confirm a field exists, redirect to `/dev/null` as in
[checks.md](checks.md#is-kv-seeded-without-printing-values).

If not: `Vault is sealed` needs the unseal key (a restart seals it).
`permission denied` means the token's policy does not cover that mount
(`kv-dev/` and `kv-prod/` are separate). A certificate error: the CA path is
wrong.

## SSH

### Reach a node or the Proxmox host

When: you need a shell on a VM, LXC or the host. Addresses are
`host_ips[...]` in `secret.yaml`; the user is `user_name` there.

```bash
ssh -i ~/.ssh/homelab_dev <user_name>@<master-01-ip>      # also worker-01, worker-02, nfs-01, vault-02, claude-code-01
ssh <admin-user>@<pve-ip>                            # Proxmox host (host_ips['pve']); admin user from pve-bootstrap.sh
```

Expect: a shell. On the host, `qm list` shows every VM; `qm agent <vmid> ping`
checks one guest agent.

If not: `Permission denied (publickey)` on a VM means the key is not the
injected one; a new key means recreating the VMs
([rebuild.md](../rebuild.md)). Talos nodes have no SSH: use
[talosctl](#fetch-the-talosconfig). Stale host keys after a rebuild:
`ssh-keygen -R <ip>`.
