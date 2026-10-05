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
