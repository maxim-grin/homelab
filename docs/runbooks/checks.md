# Health checks

Conventions (`$DEV_KC`, `$PROD_KC`, Vault address and token handling) are in
[README.md](README.md). Run from the operator's workstation unless a block
says it runs on a host. "Green" is not "works": check the thing itself.

Sections: [Vault](#vault), [ArgoCD](#argocd), [Cluster](#cluster),
[NFS](#nfs), [LAN and alerts](#lan-and-alerts), [Host](#host).

## Vault

Run these first when an app that was fine yesterday will not sync. A sealed
Vault looks healthy from everywhere except here. None of these print a
secret value.

### Is Vault up and unsealed

When: after any `vault-02` reboot, or an Application `Unknown` on sync
status. Run on `vault-02`, or from the workstation with the private CA.

```bash
export VAULT_ADDR=https://10.0.0.133:8200
export VAULT_CACERT=~/.homelab-ca/ca.crt   # not needed on vault-02 itself
vault status
```

Expect: `Initialized true` and `Sealed false`.

If not: `Sealed true` needs the unseal key; a restart seals it, a
certificate renewal only reloads it. Unseal, then
[ArgoCD](#argocd) clears on its next poll. No answer at all: the audit log
below, then `systemctl status vault` on `vault-02`.

### Is KV seeded, without printing values

When: an Application shows `ComparisonError` naming a missing path or field.
`kv list` prints names only; the field test prints nothing but a word.

```bash
export VAULT_ADDR=https://10.0.0.133:8200
export VAULT_CACERT=~/.homelab-ca/ca.crt   # not needed on vault-02 itself
printf 'Vault token: '; read -rs VAULT_TOKEN; echo; export VAULT_TOKEN
vault kv list kv-dev/monitoring
vault kv list kv-prod/monitoring
vault kv get -field=admin-user kv-prod/monitoring/grafana >/dev/null \
  && echo present || echo MISSING
unset VAULT_TOKEN
```

Expect: `kv list` names the paths under each mount (prod: `alertmanager`,
`grafana`, `pve-exporter`) and the field test prints `present`. Swap the
path and field for whatever the failing Application's `<path:...#FIELD>`
placeholder names.

If not: `MISSING` means the path or field was never seeded. Seed from
`secret.yaml`'s `kv-dev`/`kv-prod` blocks ([rebuild.md](../rebuild.md)).
Never paste the value into a command line.

### Snapshot age

When: before an upgrade, or weekly. Snapshots are daily, 14 kept, on the
`backups` share mounted at `/mnt/vault-backups`. Run on `vault-02`.

```bash
systemctl list-timers vault-snapshot.timer
ls -l --time-style=long-iso /mnt/vault-backups | tail -n 3
```

Expect: the newest `vault-<UTC timestamp>.snap` is from the last day or so,
and the timer has a next run.

If not: `systemctl status vault-snapshot.service` and
`journalctl -u vault-snapshot.service`. The script refuses to write when the
share is not mounted. Restore is in
[backups-and-recovery.md](backups-and-recovery.md).

### Audit log disk

When: Vault answers nothing though `vault status` was fine. If Vault cannot
write `/var/log/vault/audit.log` it refuses every request. Run on `vault-02`.

```bash
df -h /var/log/vault
du -h /var/log/vault/audit.log
```

Expect: free space on the filesystem holding the log.

If not: a full disk is the cause. Free space (rotate or remove old logs),
then check `vault status` again.

## ArgoCD

Each cluster has its own ArgoCD in namespace `argocd`. Dev's
Applications: `app-of-apps`, `argocd-config`, `cert-manager`,
`cert-manager-issuers`, `ingress-nginx`, `jobboard`, `monitoring`, `nfs`.
Prod's: `alerts`, `app-of-apps`, `argocd-config`, `cert-manager`,
`cert-manager-issuers`, `ingress-nginx`, `monitoring-secrets`,
`monitoring`, `nfs`, `pve-exporter`.

### List Applications with sync and health

When: after a merge to `main` (Argo polls about every 3 minutes), or any
time something looks off.

```bash
kubectl --kubeconfig "$DEV_KC" -n argocd get applications | grep -E '^NAME|monitoring'
kubectl --kubeconfig "$PROD_KC" -n argocd get applications | grep -E '^NAME|monitoring'
```

Expect: every row `Synced` and `Healthy`. Drop the `grep` to list every
Application.

If not: `OutOfSync` after a merge may just be the poll interval; refresh
below. `Unknown` sync status is the next check.

### Spot ComparisonError (the sealed-Vault tell)

When: an Application is `Unknown` on sync status. A sealed Vault leaves
health `Healthy`, so the health column lies; the condition tells the truth.

```bash
kubectl --kubeconfig "$DEV_KC" -n argocd get applications \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\t"}{range .status.conditions[*]}{.type}{" "}{end}{"\n"}{end}'
kubectl --kubeconfig "$PROD_KC" -n argocd get applications \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\t"}{range .status.conditions[*]}{.type}{" "}{end}{"\n"}{end}'
```

Expect: no `ComparisonError` in the last column.

If not: [Is Vault up and unsealed](#is-vault-up-and-unsealed) first. If
Vault is unsealed, read the condition message for AVP's stderr:
`kubectl --kubeconfig "$PROD_KC" -n argocd get application <name> -o yaml`
and look under `status.conditions`. An Application that needs a path
Vault does not hold yet (for example `pve-exporter` before its seed)
shows it harmlessly until seeded.

### Refresh an Application

When: a merge is on `main` and you do not want to wait for the poll. A hard
refresh re-compares only; it does not retry an exhausted sync.

```bash
APP=monitoring
# dev
kubectl --kubeconfig "$DEV_KC" -n argocd annotate application "$APP" \
  argocd.argoproj.io/refresh=hard --overwrite
# prod
kubectl --kubeconfig "$PROD_KC" -n argocd annotate application "$APP" \
  argocd.argoproj.io/refresh=hard --overwrite
```

Expect: the Application re-compares within seconds. Run the one for the
cluster that failed; an Application that exists on one cluster only errors
on the other.

If not: a `Sync failed` Application with its retries used up needs a
manual sync, below.

### Sync an Application by hand

When: an Application is `Sync failed` with retries exhausted, typically
after Vault was sealed. Unseal first. Needs kubectl alone, no `argocd` CLI.

```bash
APP=monitoring
# dev
kubectl --kubeconfig "$DEV_KC" -n argocd patch application "$APP" \
  --type merge \
  -p '{"operation":{"initiatedBy":{"username":"operator"},"sync":{}}}'
# prod
kubectl --kubeconfig "$PROD_KC" -n argocd patch application "$APP" \
  --type merge \
  -p '{"operation":{"initiatedBy":{"username":"operator"},"sync":{}}}'
```

Expect: the Application moves to `Synced` and `Healthy` shortly after. Run
the one for the cluster that failed. An
empty `sync` uses the Application's own sources and `syncPolicy`.

If not: the `ComparisonError` check above. Prod's `monitoring` needs the
`monitoring` namespace that `monitoring-secrets` owns, so sync
`monitoring-secrets` first ([rebuild.md](../rebuild.md), step 18.2).

### Check the CMP sidecar

When: once, before the first app moves into the set
([ADR 0026](../decisions/0026-uniform-apps.md)), and after any change to the
AVP sidecar image or `argocd_avp_plugin_config`. Every set-generated
Application renders through the `avp` container with
`kustomize build --enable-helm`, so the sidecar must have `helm` and
`kustomize`, must be able to write Helm's directories, and must render the
largest chart inside the repo-server's exec timeout (default 90 seconds).
Nothing is committed or applied. The unreachable `VAULT_ADDR` is a
throwaway address in the TEST-NET range.

```bash
R="$(kubectl --kubeconfig "$PROD_KC" -n argocd get pod \
  -l app.kubernetes.io/name=argocd-repo-server -o name | head -1)"
kubectl --kubeconfig "$PROD_KC" -n argocd get deploy argocd-applicationset-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}{.status.readyReplicas}{"\n"}'
kubectl --kubeconfig "$PROD_KC" -n argocd exec "$R" -c avp -- sh -c 'helm version; kustomize version'
# AVP on a manifest with no placeholder: does it still try to log in?
kubectl --kubeconfig "$PROD_KC" -n argocd exec -i "$R" -c avp -- \
  env VAULT_ADDR=https://192.0.2.1:8200 argocd-vault-plugin generate - <<'EOF2'
apiVersion: v1
kind: ConfigMap
metadata:
  name: no-placeholder
EOF2
# the heaviest render, timed, with Helm's dirs under /tmp
kubectl --kubeconfig "$PROD_KC" -n argocd exec "$R" -c avp -- sh -c '
  export HELM_CACHE_HOME=/tmp/h/cache HELM_CONFIG_HOME=/tmp/h/config HELM_DATA_HOME=/tmp/h/data
  d=$(mktemp -d); cd "$d"
  printf "helmCharts:\n  - name: kube-prometheus-stack\n    repo: https://prometheus-community.github.io/helm-charts\n    version: 91.9.0\n    releaseName: monitoring\n    includeCRDs: true\n" > kustomization.yaml
  time kustomize build --enable-helm . | wc -l; ls; rm -rf "$d"'
```

Expect: the applicationset controller image tag and `1` ready replica; both
binaries print a version; the placeholder-free generate either prints the
ConfigMap or fails, and the result is the finding: if it errors on the
unreachable address, AVP logs in regardless, which is why the CMP calls it
only when `<path:` is present. The render finishes well under 90 seconds
and prints a `charts` directory in the listing: `--enable-helm` writes
`charts/` under the app directory, which is gitignored.

If not: no `helm` binary means the sidecar image or an init container has
to supply it; a read-only filesystem error means the three `HELM_*`
directories in the plugin's `generate` command are not under `/tmp`; a
render over 90 seconds means raising the repo-server's exec timeout
(`ARGOCD_EXEC_TIMEOUT`) before moving `kube-prometheus-stack`.

### Verify the ApplicationSet

When: BEFORE merging any change to
`argocd/environments/prod/applications/appset.yaml` or a config entry,
including the PR that adds the set. This is the only proof that Argo
accepts the templated `env` selector inside the matrix and drops empty
configs; `scripts/check-appsets.sh` expands the set with `yq`, not with
Argo's own generators. The git generator reads its repository at
`revision`, so run it against the pushed branch, never `main`: before the
merge `main` has no `config.yaml`, and the check passes falsely. Set
`revision` in the local copy of the set to the branch; that edit is a
scratch change: revert it and never commit it. `argocd` is the CLI,
logged in to prod or run with `--core`.

```bash
# scratch: point the git generator at the pushed branch (never commit this)
yq -i '.spec.generators[0].matrix.generators[0].git.revision = "<branch>"' \
  argocd/environments/prod/applications/appset.yaml
argocd appset generate argocd/environments/prod/applications/appset.yaml
# with one scratch entry (env: prod, namespace, createNamespace,
# serverSideApply) in one app's config.yaml, pushed to the branch:
argocd appset generate argocd/environments/prod/applications/appset.yaml
git checkout -- argocd/environments/prod/applications/appset.yaml
```

Expect: while every `config.yaml` is `[]`, no Applications and no error
(no `ErrorOccurred` condition, nothing about a missing `env` key). With
the one scratch entry, exactly one Application, `prod-<dir>`, with source
path `argocd/apps/<dir>/prod`. Remove the scratch entry from the branch
before merging.

If not: `map has no entry for key "env"` means empty configs are not
dropped: the git child's `selector` (`env` `Exists`) is missing or not
honoured ([ADR 0026](../decisions/0026-uniform-apps.md) names the
fallback). Any other error naming the selector or a template key is the
finding; fix the set before it reaches `main`.

### Roll an app into the set

When: moving one app from its own Application to the set, one PR per group
([ADR 0026](../decisions/0026-uniform-apps.md)). `<old>` is the old
Application's name, `<new>` is `prod-<dir>`.

```bash
# Vault must be unsealed first
ssh vault-02 'VAULT_ADDR=https://10.0.0.133:8200 vault status'
# before merging: stop the old Application cascading when it is pruned
kubectl --kubeconfig "$PROD_KC" -n argocd patch application <old> \
  --type merge -p '{"metadata":{"finalizers":null}}'
# after merging: the old one is pruned by root-prod, the new one appears
kubectl --kubeconfig "$PROD_KC" -n argocd get applications | grep -E '^NAME|<old>|<new>'
kubectl --kubeconfig "$PROD_KC" get pods,certificate -A -o wide | grep <namespace>
```

The PR replaces `[]` in the app's `config.yaml` with the uncommented entry
and deletes the old Application file in the same commit. Wait for
`root-prod` to prune the old Application (about 3 minutes) and for the set
to create `<new>`.

Expect: `<old>` gone, `<new>` `Synced` and `Healthy`, and nothing
recreated: pod and certificate ages are older than the merge. A hook Job in
the chart (cert-manager, ingress-nginx) behaves as before; that is
confirmed here, not assumed.

If not: adoption failed. Delete the old Application's remaining resources
and let `<new>` recreate them (the fallback, not the plan). For
cert-manager rehearse first against `letsencrypt-staging`: Let's Encrypt
allows five duplicate production certificates per week
([ADR 0008](../decisions/0008-acme-dns01-not-http01.md)). Anything stuck:
[Sync an Application by hand](#sync-an-application-by-hand).

### Retire an app from the set

When: an app leaves a cluster. The set never deletes Applications
(`applicationsSync: create-update`), so removing the config entry alone
leaves the generated Application running; and an Application deleted while
its entry is still on `main` is recreated by the set. So: merge the PR that
leaves `[]` in the app's `config.yaml` (and removes nothing else), then
delete the Application.

```bash
# <new> is the generated Application, prod-<dir>. Its finalizer cascades, so
# the app's resources go too. Run the patch only to keep them.
# optional: keeps the app's resources
kubectl --kubeconfig "$PROD_KC" -n argocd patch application <new> \
  --type merge -p '{"metadata":{"finalizers":null}}'
kubectl --kubeconfig "$PROD_KC" -n argocd delete application <new>
```

Expect: `<new>` gone from `kubectl -n argocd get applications` and not
recreated after the next poll; the resources gone, or kept if the patch
ran. Skip the patch to remove them. If not: the entry is still on `main`.

### Prove AVP end to end

When: after a Vault, ArgoCD or auth-mount change, or a rebuild. Runs the
plugin in the repo-server's `avp` sidecar. Nothing is committed or applied.
The dev probe pipes through `grep -c` so no value is printed.

```bash
kubectl --kubeconfig "$PROD_KC" -n argocd exec -i \
  deploy/argocd-repo-server -c avp -- \
  argocd-vault-plugin generate - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: avp-check
  annotations:
    avp.kubernetes.io/path: kv-prod/data/monitoring/grafana
data:
  user: <admin-user>
EOF
kubectl --kubeconfig "$DEV_KC" -n argocd exec -i \
  deploy/argocd-repo-server -c avp -- \
  argocd-vault-plugin generate - <<'EOF' | grep -c 'probe: [^<]'
apiVersion: v1
kind: ConfigMap
metadata:
  name: avp-check
  annotations:
    avp.kubernetes.io/path: kv-dev/data/monitoring/prometheus
data:
  probe: <auth>
EOF
```

Expect: prod prints a ConfigMap whose `user` is `admin` (the field is
`admin-user`, not the password). Dev prints `1` (the placeholder was
replaced; no value shown).

If not: a non-zero exit with an error from Vault or the login is the same
error an Application reports as `ComparisonError`. Check
[Vault status](#is-vault-up-and-unsealed) first, then that the path is
seeded.

## Cluster

### Nodes

When: first look at a cluster.

```bash
kubectl --kubeconfig "$DEV_KC" get nodes
kubectl --kubeconfig "$PROD_KC" get nodes
```

Expect: every node `Ready`. Prod has three (one control plane, two workers).

If not: `kubectl describe node <name>`. On dev, disk pressure has evicted
pods before; check the node's disk.

### Pods not running

When: after any rollout, or a symptom with no obvious cause.

```bash
kubectl --kubeconfig "$DEV_KC" get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl --kubeconfig "$PROD_KC" get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

Expect: no rows.

If not: `kubectl -n <ns> describe pod <name>`. `Pending` with a PVC is
the NFS provisioner: see [PVCs](#pvcs-and-the-nfs-provisioner).

### PVCs and the NFS provisioner

When: a pod is `Pending`, or after touching `nfs-01`. `nfs-dev` is dev's
default StorageClass and `nfs-prod` is prod's. Their provisioners are the
deployments `nfs-client-provisioner-dev` and `nfs-client-provisioner-prod` in
namespace `nfs-system`.

```bash
kubectl --kubeconfig "$DEV_KC" get pvc -A
kubectl --kubeconfig "$DEV_KC" -n nfs-system get deployment nfs-client-provisioner-dev
kubectl --kubeconfig "$PROD_KC" get pvc -A
kubectl --kubeconfig "$PROD_KC" -n nfs-system get deployment nfs-client-provisioner-prod
```

Expect: every PVC `Bound`, none `Pending`; on prod, Prometheus (20Gi) and
Grafana (5Gi) on `nfs-prod`. The provisioner deployment is `1/1`.

If not: provisioner down means every PVC without a class waits. Check
`kubectl -n nfs-system describe deployment`, then [NFS](#nfs).

### Certificates

When: a TLS name fails, or after an issuer change.

```bash
kubectl --kubeconfig "$DEV_KC" get certificate -A
kubectl --kubeconfig "$PROD_KC" get certificate -A
```

Expect: `READY` `True` for every row. Prod includes `grafana-tls` in
`monitoring` and `argocd-server-tls` in `argocd`.

If not: `kubectl describe certificate <name>`, then
`kubectl get challenges -A`. Debug with the staging issuer first: point the
Ingress annotation `cert-manager.io/cluster-issuer` at `letsencrypt-staging`
(production allows 5 failed validations per hostname per hour). For DNS-01,
the Cloudflare token comes from Vault (`kv-dev/cert-manager/cloudflare`,
`kv-prod/cert-manager/cloudflare`).

### Ingress

When: a `*.mgryn.cc` name does not load. ingress-nginx is a DaemonSet on
host ports 80 and 443 in namespace `ingress-nginx`.

```bash
kubectl --kubeconfig "$DEV_KC" get ingress -A
kubectl --kubeconfig "$DEV_KC" -n ingress-nginx get ds
kubectl --kubeconfig "$PROD_KC" get ingress -A
kubectl --kubeconfig "$PROD_KC" -n ingress-nginx get ds
```

Expect: each Ingress lists an address; the DaemonSet `READY` equals
`DESIRED`. Prod runs it on the two workers only (2).

If not: `kubectl -n ingress-nginx describe ds ingress-nginx-controller`; a
`FailedCreate` event names a refused pod. Then curl a node with the right
`Host:` header, for example prod's Grafana:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: grafana.mgryn.cc' https://10.0.0.111/
curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: grafana.mgryn.cc' https://10.0.0.112/
```

Expect `302` or `200` from both.

## NFS

Both clusters use `nfs-01`. The `nfs-dev` share path is `/srv/nfs/k8s`;
`nfs-prod` is exported to the two prod workers only (`10.0.0.111`,
`10.0.0.112`).

### Exports

When: PVCs stuck `Pending`, or after running the `nfs_server` playbook.
Run on `nfs-01` (`showmount` also works from any LAN host with the NFS
client tools).

```bash
showmount -e localhost
sudo exportfs -v
```

Expect: the dev path exported to the dev nodes, and the prod path listing
exactly the two prod worker addresses.

If not: `systemctl status nfs-server` on `nfs-01`. The server will not
start until all three share disks (`scsi1` dev, `scsi2` prod, `scsi3`
backups) are mounted. Re-run the `nfs_server` playbook
([playbooks-and-terraform.md](playbooks-and-terraform.md)).

## LAN and alerts

### Gatus and Glance

When: a LAN service seems down, or on a routine look.

Open `https://status.hl.mgryn.cc` (Gatus) and `https://home.hl.mgryn.cc`
(Glance), or from the shell:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://status.hl.mgryn.cc/
curl -s -o /dev/null -w '%{http_code}\n' https://home.hl.mgryn.cc/
```

Expect: both below 400 (these are the same conditions Gatus checks), and
every Gatus endpoint green, including `argocd.mgryn.cc` and
`grafana.mgryn.cc` in group `prod`. Gatus alerts to Telegram within about
two minutes of a failure.

If not: Glance's Services widget showing ERROR for every hostname is a stale
`/etc/resolv.conf` in a LAN container
([operations.md](../operations.md), "Stale resolv.conf after a nameserver
change"). Otherwise rerun the LAN services playbook
([playbooks-and-terraform.md](playbooks-and-terraform.md)).

### Prometheus targets (prod)

When: an alert says a metric is absent, or after the alerting rollout.
Dev's Prometheus is at `http://prometheus.mgryn.cc` (basic auth, the login
is in Vault at `kv-dev/monitoring/prometheus`); its `/targets` page lists
the targets. Prod has no Ingress for it; port-forward in its own terminal.

```bash
kubectl --kubeconfig "$PROD_KC" -n monitoring port-forward \
  svc/monitoring-kube-prometheus-prometheus 9090
```

Then open `http://localhost:9090/targets` and `/alerts`.

Expect: `pve-exporter`, `monitoring/ingress-nginx-controller` and
`monitoring/cert-manager-controller` targets `UP`.

If not: a `DOWN` pve-exporter target is explained by
`kubectl --kubeconfig "$PROD_KC" -n monitoring logs deploy/pve-exporter`.
Other absent-metric alerts: `IngressNginxMetricsAbsent`,
`CertManagerMetricsAbsent`, `ProxmoxPoolMetricsAbsent`
([operations.md](../operations.md), "Alerts").

### Alertmanager and the Watchdog heartbeat (prod)

When: you suspect alerting is broken. `Watchdog` always fires by design and
goes to a `null` receiver, so it never reaches Telegram: its absence from
Alertmanager's alert list is the failure. Port-forward in its own terminal,
then query.

Terminal 1:

```bash
kubectl --kubeconfig "$PROD_KC" -n monitoring port-forward \
  svc/monitoring-kube-prometheus-alertmanager 9093
```

Terminal 2:

```bash
amtool alert query --alertmanager.url=http://localhost:9093 | grep Watchdog
```

Expect: a `Watchdog` row.

If not: no `Watchdog` means the rule or scrape path is broken, not Telegram.
Check Prometheus targets above.

### Telegram test alert (prod)

When: after changing Alertmanager's config, its Vault secret, or the
Telegram settings (`kv-prod/monitoring/alertmanager`). With terminal 1 from the
previous entry still open (the Alertmanager port-forward), in terminal 2:

```bash
amtool alert add testalert severity=warning namespace=monitoring \
  --alertmanager.url=http://localhost:9093
```

Expect: a Telegram message headed `TICKET testalert in monitoring` within
about 2 minutes. Let it expire on its own; a `RESOLVED` message follows.
Do not silence it, since a silenced alert sends no `RESOLVED`.

If not: work the checklist in [operations.md](../operations.md), "A Telegram
message does not arrive": the alert list, Alertmanager's notify errors,
that the `alertmanager-config` Secret rendered (no literal `<path:`), and
that Vault is unsealed. Prod only: dev has no Alertmanager.

## Host

The Proxmox host is `pve`. Run these as root on it.

### Memory, VMs and thin pool

When: before adding a VM or disk, after a rebuild, or on a
`ProxmoxThinPoolNearlyFull` alert. `local-lvm` is an LVM thin pool that is
deliberately overcommitted, so watch actual use, not declared sizes.

```bash
free -m
qm list
lvs -o lv_name,data_percent pve
```

Expect: `available` memory stays above 1000 MiB; every expected VM is
`running`; the `data` volume's `Data%` is below 80.

If not: the alert fires at 80% for 10 minutes, and at 100% every guest gets
I/O errors. Find what grew (`lvs -o lv_name,lv_size,data_percent,metadata_percent pve`),
and see [rebuild.md](../rebuild.md), "Disk capacity". A VM not running:
`qm start <vmid>` then `qm agent <vmid> ping`.
