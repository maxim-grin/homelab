# Backups and recovery

Conventions (`$DEV_KC`, `$PROD_KC`, Vault address and token handling) are in
[README.md](README.md). Run from the operator's workstation unless a block
says it runs on a host. Nothing here prints a secret value.

Almost nothing is backed up off the machine. Vault snapshots land on
`nfs-01`, which is on the same SSD as everything else, so they cover a bad
upgrade or a deleted secret, not a lost disk.

Sections: [Vault snapshots](#vault-snapshots),
[Restore Vault](#restore-vault), [What has no backup](#what-has-no-backup),
[Clean up retained nfs-prod volumes](#clean-up-retained-nfs-prod-volumes),
[Dump jobboard's database](#dump-jobboards-database),
[Restore jobboard's database on dev](#restore-jobboards-database-on-dev),
[Restore jobboard's database into prod](#restore-jobboards-database-into-prod),
[Flip jobs.mgryn.cc to prod](#flip-jobsmgryncc-to-prod),
[Rebuild pointers](#rebuild-pointers).

## Vault snapshots

### Check the snapshot job

When: before an upgrade, or weekly. A systemd timer on `vault-02`
(`vault-snapshot.timer`, `OnCalendar=daily`, up to 15 minutes of random
delay) runs `vault-snapshot.service`, which saves
`vault-<UTC timestamp>.snap` to the `backups` share and keeps the newest 14.
The share is `/srv/nfs/backups` on `nfs-01`, mounted at
`/mnt/vault-backups` on `vault-02`. Run on `vault-02`.

```bash
systemctl list-timers vault-snapshot.timer
ls -l --time-style=long-iso /mnt/vault-backups | tail -n 3
```

Expect: the newest `.snap` is from the last day or so and the timer has a
next run.

If not: `systemctl status vault-snapshot.service` and
`journalctl -u vault-snapshot.service`. The script refuses to write when the
share is not mounted, so a missing mount means no snapshots, not an error
anywhere else. More in [checks.md](checks.md).

## Restore Vault

### Restore a raft snapshot

When: a bad Vault upgrade, a deleted or overwritten secret, or a
`vault-02` rebuilt on its own while `nfs-01` and its snapshots survive. Not
after a lost SSD, which takes the snapshots with it: rebuild Vault fresh
and re-seed it ([Seed](playbooks-and-terraform.md#seed)).

Warning: this overwrites all of Vault's current data with the snapshot's.
Anything written after the snapshot is gone. Check first which file you are
restoring and that it is the one you want:

```bash
ls -l --time-style=long-iso /mnt/vault-backups
```

Token sequence (rebuild.md gives the restore command but no token step; the
Vault API needs an authenticated token for any request, so the prompt below
is this runbook's addition):

1. Fresh `vault-02`: `vault operator init` and `vault operator unseal`
   produce a new unseal key and root token. The restore command needs a
   token valid now: enter that new root token at the prompt. Already-running
   Vault being rolled back: enter its current root token.
2. The restore replaces the store with the snapshot's. From then on only the
   ORIGINAL unseal key and ORIGINAL root token (the ones recorded when the
   snapshot's data was written) work; the new ones are void.

Run on `vault-02`; `<file>` is a name from the listing above.

```bash
export VAULT_ADDR=https://${VAULT_IP:?}:8200
printf 'Vault token: '; read -rs VAULT_TOKEN; echo; export VAULT_TOKEN   # current root token, before the restore
vault operator raft snapshot restore -force /mnt/vault-backups/<file>
unset VAULT_TOKEN
```

Expect: no error. Then unseal with the original unseal key, log in with the
original root token, and run `vault status`.

If not: a permission or token error on the restore means the token entered
is not valid in the store as it stands now (on a fresh init, use the new
root token from that init). After a successful restore, a rejected unseal
key or token means you are using the new ones instead of the originals.
`Sealed true` after the restore is normal until the original key is used.
Without the original key and token the snapshot cannot be used. The full
procedure is in
[rebuild.md](../rebuild.md#restoring-vault-from-a-snapshot); apps recover on
Argo's next poll once Vault is unsealed.

## What has no backup

These exist only on the operator's workstation or in a password manager.
Losing one is not recoverable from git or from the cluster.

| Item | Why it matters |
| ---- | -------------- |
| `*.tfvars` (`dev.tfvars`, `shared.tfvars`, `prod.tfvars`) | Proxmox API token and cloud-init password. Recreate from the committed `.example` files and refill the secrets. |
| The ansible-vault password | Unlocks `ansible/secret.yaml`, the only record of every host address and vmid. Without it the file is unrecoverable. Keep it in a password manager. |
| `~/.homelab-ca/` (private CA key) | Signs Vault's TLS certificate. Regenerable: re-run the vault role and refresh the `vault-ca` ConfigMap. No data is lost. |
| `terraform/environments/prod/terraform.tfstate` | Holds the Talos PKI and the kubeconfig. Lost state means rebuilding the prod cluster. |
| The Vault unseal key and root token | Without them an existing Vault stays sealed and no snapshot can be restored. A lost disk needs neither: a rebuild initialises Vault fresh and re-seeds it from `secret.yaml`. |

Only Vault has snapshots; everything else on the NFS export is lost with
the SSD. Details and the full table:
[rebuild.md](../rebuild.md#4-files-that-live-only-on-the-workstation) and
[rebuild.md](../rebuild.md#what-is-destroyed-and-not-backed-up).

## Clean up retained nfs-prod volumes

When: a prod PVC was deleted and its data is no longer wanted. The
`nfs-prod` StorageClass has `reclaimPolicy: Retain` and
`archiveOnDelete: "true"`: deleting a PVC leaves the PV `Released` and its
data directory under `/srv/nfs/prod` on `nfs-01`. Nothing deletes them.

Warning: this destroys the PV object and, on `nfs-01`, the data directory.
Check first that nothing wants the data. From the repo root, list the PVs;
look for `STATUS` `Released` and read the `CLAIM` column to confirm it is the
deleted PVC's:

```bash
KC_TMP="$(mktemp)"
( cd "$(git rev-parse --show-toplevel)/terraform/environments/prod" && terraform output -raw kubeconfig ) > "$KC_TMP"
kubectl --kubeconfig "$KC_TMP" get pv | grep -E '^NAME|Released'
echo "kubeconfig is at $KC_TMP"
```

Then delete the PV, with `<pv-name>` from that list and the same
kubeconfig path, and `rm` the file when done:

```bash
kubectl --kubeconfig <kubeconfig-path> delete pv <pv-name>
rm <kubeconfig-path>
```

Then remove its directory under `/srv/nfs/prod` on `nfs-01` (SSH in as in
[access.md](access.md)); list first and match the directory to the PV.

```bash
ls -l /srv/nfs/prod
```

Expect: typically one directory per PV, named for the namespace, PVC and PV
by the provisioner's default naming (not set in this repo). Remove
only the one that matches with `sudo rm -r /srv/nfs/prod/<directory>`.

If not: a PV that is `Bound` is in use; do not delete it. A PV listed as
`Released` whose directory is missing needs no further action. Source:
[rebuild.md](../rebuild.md) step 18, "Cleaning up retained volumes".

## Dump jobboard's database

When: before anything that can lose prod's volumes (a prod rebuild, the SSD
rebuild), and routinely after the flip, since prod takes writes. The rows
exist only in prod's Postgres. Run from the job-board repo (`~/job-board`):

```bash
DUMP=jobboard-prod-$(date +%F).dump
KUBECONFIG="${PROD_KC:?}" tools/db-backup.sh dump "$DUMP"
```

Dev is staging; dump it with `KUBECONFIG="${DEV_KC:?}"` only if its rows
matter.

The script runs `pg_dump` in the `postgres` StatefulSet's pod (default
`kubectl -n jobboard exec -i statefulset/postgres --`, so name the cluster
as shown), checksums the copy and validates it with `pg_restore -l`. Copy
the file off the workstation, then on each machine holding a copy:

```bash
sha256sum "$DUMP"
pg_restore --list "$DUMP" >/dev/null; echo "pg_restore rc=$?"
```

Expect: the same digest everywhere and `pg_restore rc=0`. If not: the copy
is bad; take another before you destroy anything.

To prove a dump restores, load it into job-board's local compose database
(docker on the workstation, after `docker compose up -d postgres`), never
into the live pod:

```bash
JOBBOARD_PG_EXEC="docker compose exec -T postgres" tools/db-backup.sh restore "$DUMP" --yes
```

Do not set `KUBECONFIG` for that command: it would restore over a live
cluster.

## Restore jobboard's database on dev

### Hold dev-jobboard still

When: before copying an old Postgres data directory into a new PVC (order
in [rebuild.md](../rebuild.md#the-new-cluster-starts-with-empty-volumes)).
Hand-editing the generated `dev-jobboard` Application is not enough: the
`apps` ApplicationSet owns it and reverts the edit within seconds, and
selfHeal then scales Postgres back up mid-copy. Stop the ApplicationSet
controller first, not the application controller, so every other prod app
keeps self-healing. `$PROD_KC` is the prod kubeconfig
([Kubeconfigs](access.md#kubeconfigs)); the `argocd` CLI is logged in
([Log in to the ArgoCD CLI](access.md#log-in-to-the-argocd-cli)).

```bash
kubectl --kubeconfig "${PROD_KC:?}" -n argocd scale deploy/argocd-applicationset-controller --replicas=0
argocd app set dev-jobboard --sync-policy none --grpc-web
kubectl --kubeconfig "$PROD_KC" -n argocd get application dev-jobboard -o jsonpath='{.spec.syncPolicy.automated}'
```

Expect: the first command prints `deployment.apps/argocd-applicationset-controller scaled`;
`argocd app set` prints nothing on success, and the last command prints
nothing (no automated policy). While the controller
is at 0 every other generated app keeps self-healing, but changes to config
entries or the set's template are not processed and generated Applications
are not updated.

Do the restore with the app scaled to zero for its whole length. Then
release the set:

```bash
kubectl --kubeconfig "${PROD_KC:?}" -n argocd scale deploy/argocd-applicationset-controller --replicas=1
kubectl --kubeconfig "$PROD_KC" -n argocd get deploy argocd-applicationset-controller
```

Expect: `1/1` ready, and within a minute `argocd app get dev-jobboard`
shows the automated sync policy (prune and self-heal) back, restored by the
set. Scaling the controller back to 1 is the last step; do not skip it, or no
generated Application is ever updated again.

If not: `0/1` after a minute, describe the Deployment's pods; the sync
policy still `none` means the controller is not running.

## Restore jobboard's database into prod

### Restore the dump into prod-jobboard

When: first start of `prod-jobboard` (its Postgres is empty), or a prod
rebuild. For the first cutover the data is the dump of 2026-10-09
(`jobboard-dev-2026-10-09.dump`): 76,425,607 bytes, sha256
`d4922fc872ebe7c808f861eb53802215234b36f034a036eb5b5749f610f6903b`; keep
every copy of it until the SSD drill. For a rebuild use the newest prod dump
([Dump jobboard's database](#dump-jobboards-database)) and its own digest,
since the 2026-10-11 dump loses every row written since the flip. `restore` runs `pg_restore --clean
--if-exists --no-owner --single-transaction`, so it is safe over a database
the app has already migrated, and a failure rolls back whole.

Gate: `prod-nfs-provisioner` Healthy, Vault unsealed, the
[seed check](checks.md#check-the-prod-jobboard-seed) all `present`, and
`prod-jobboard` generated with its Postgres PVC `Bound`
(`kubectl --kubeconfig "$PROD_KC" -n jobboard get pvc`). Read the memory of
both prod workers and `cp1` before and after the first sync
([Memory, VMs and thin pool](checks.md#memory-vms-and-thin-pool)); `cp1`
sits at 80% of 4 GiB.

Hold `prod-jobboard` the way
[Hold dev-jobboard still](#hold-dev-jobboard-still) does (stop the
ApplicationSet controller, not the application controller), with
`prod-jobboard` for `dev-jobboard`, and scale only the app to zero; Postgres
must stay up:

```bash
kubectl --kubeconfig "${PROD_KC:?}" -n argocd scale deploy/argocd-applicationset-controller --replicas=0
argocd app set prod-jobboard --sync-policy none --grpc-web
kubectl --kubeconfig "$PROD_KC" -n jobboard scale deploy/jobboard --replicas=0
kubectl --kubeconfig "$PROD_KC" -n jobboard rollout status sts/postgres
kubectl --kubeconfig "$PROD_KC" -n argocd get application prod-jobboard -o jsonpath='{.spec.syncPolicy.automated}'
```

Expect the last command to print nothing (no automated policy).

Then, from the job-board repo (`~/job-board`) on the machine holding the
dump:

```bash
DUMP=~/jobboard-dev-2026-10-09.dump   # or the newest prod dump
sha256sum "$DUMP"
pg_restore --list "$DUMP" >/dev/null; echo "pg_restore rc=$?"
KUBECONFIG="${PROD_KC:?}" tools/db-backup.sh restore "$DUMP" --yes
```

Expect: the digest above, `pg_restore rc=0` (a local `pg_restore` older than the dump's Postgres 17
fails with `unsupported version (1.16)`; that is the tool, not the dump), and `restored <the file>
into jobboard`. Compare row counts with the dump's own: load the dump into
job-board's local compose database (the command in
[Dump jobboard's database](#dump-jobboards-database)), count there with
`docker compose exec -T postgres psql -U jobboard -d jobboard -c '<the query below>'`,
then count in prod and compare:

```bash
kubectl --kubeconfig "$PROD_KC" -n jobboard exec statefulset/postgres -- \
  psql -U jobboard -d jobboard -c 'select (select count(*) from users) users, (select count(*) from jobs) jobs, (select count(*) from companies) companies'
```

Release: scale the app back, then the set, as the last lines of
[Hold dev-jobboard still](#hold-dev-jobboard-still) say:

```bash
kubectl --kubeconfig "$PROD_KC" -n jobboard scale deploy/jobboard --replicas=1
kubectl --kubeconfig "$PROD_KC" -n argocd scale deploy/argocd-applicationset-controller --replicas=1
kubectl --kubeconfig "$PROD_KC" -n argocd get deploy argocd-applicationset-controller
```

Expect: `1/1` ready, `argocd app get prod-jobboard --grpc-web` shows the automated policy
back within a minute, and the app pod `Ready`. If not: a digest mismatch
means the copy is bad, stop; a `pg_restore` error rolled back, so fix the
cause and run it again; the policy still `none` means the controller is
still at 0.

## Flip jobs.mgryn.cc to prod

### Move the DNS record

When: the restore above has finished and the app is running in prod. Do
this last, so the rollback is flipping the record back.

Prove prod before DNS, from the workstation, against each worker:

```bash
for ip in $PROD_W1_IP $PROD_W2_IP; do
  curl -sk -o /dev/null -w "$ip %{http_code}\n" --resolve jobs.mgryn.cc:443:$ip https://jobs.mgryn.cc/
done
kubectl --kubeconfig "${PROD_KC:?}" -n jobboard get certificate jobboard-tls
```

Expect: `303` from both (the login page) and the certificate `READY`
`True`. Without `-k`, the chain should verify too once the certificate is
issued. Then log in with a restored account in a browser pointed at prod
(add `$PROD_W1_IP jobs.mgryn.cc` to `/etc/hosts` for the proof, then remove
it with `sudo sed -i.bak '/jobs\.mgryn\.cc/d' /etc/hosts`) and confirm the restored rows are there.

In Cloudflare, with every record DNS-only (grey cloud), change the A record
for `jobs.mgryn.cc` from the dev node `$DEV_NODE_IP` to two records, `$PROD_W1_IP`
and `$PROD_W2_IP`. Add `dev-jobs.mgryn.cc` -> `$DEV_NODE_IP` for dev's staging copy, which
its ingress already serves under that name. Verify by
name:

```bash
dig +short jobs.mgryn.cc @1.1.1.1
curl -s -o /dev/null -w '%{http_code}\n' https://jobs.mgryn.cc/
```

Expect: both worker IPs and `303`, with a verified certificate.
Mind the record's TTL and the workstation's resolver cache.

Rollback before the flip: scale `prod-jobboard` to 0 (hold it as in the
restore entry) and stop; DNS never moved. Rollback after the flip: point the
record back to `$DEV_NODE_IP`. Dev's jobboard still has its own certificate
and an empty database, so rows written to prod after the flip are not
carried back to dev. If not working: `kubectl --kubeconfig "$PROD_KC" -n
jobboard describe certificate jobboard-tls` and `get order,challenge` on prod; debug with
`letsencrypt-staging` as in [Certificates](checks.md#certificates).

## Before an SSD swap

### Check the off-box set

When: before swapping the SSD or any rebuild that loses prod's volumes. Prod
holds one thing that cannot be regenerated, jobboard's database; Vault
rebuilds from `ansible/secret.yaml`'s seed and the apps from git, so a lost
disk needs no Vault snapshot. Prints digests and words, never a secret.

1. Take a fresh prod dump ([Dump jobboard's database](#dump-jobboards-database))
   with the apps quiet, then record its digest and keep a second copy on
   another device:

   ```bash
   shasum -a 256 "$DUMP"
   ```

   Run the same command on the second copy; the digests must match.

2. The workstation-only files exist ([rebuild.md](../rebuild.md#4-files-that-live-only-on-the-workstation)).
   From the repo root:

   ```bash
   for f in terraform/environments/dev/dev.tfvars \
            terraform/environments/shared/shared.tfvars \
            terraform/environments/prod/prod.tfvars \
            terraform/environments/prod/backend.tf \
            terraform/environments/prod/terraform.tfstate \
            ~/.ssh/homelab_dev ~/.homelab-ca/ca.crt; do
     [ -e "$f" ] && echo "present  $f" || echo "MISSING  $f"
   done
   ```

3. The ansible-vault password opens the file (it asks for it):

   ```bash
   ansible-vault view ansible/secret.yaml >/dev/null; echo "rc=$?"
   ```

4. Every prod and dev app is Synced and Healthy
   ([List Applications with sync and health](checks.md#list-applications-with-sync-and-health)),
   so the swap starts from a known-good state.

5. By hand: the Vault unseal key and root token are in the password
   manager. After the swap the old pair is useless, since a rebuilt Vault is
   initialised fresh; record the new pair straight after
   `vault operator init`.

Expect: matching digests, no `MISSING`, `rc=0`, and all apps healthy. If not:
fix it before the swap; a missing tfvars is recreated from its `.example`,
a lost ansible-vault password is not recoverable.

## Rebuild pointers

- Whole rebuild, in order: [rebuild.md](../rebuild.md#rebuild-order).
- Dev only: [rebuild.md](../rebuild.md#rebuilding-dev-only); the new cluster
  starts with empty volumes
  ([rebuild.md](../rebuild.md#the-new-cluster-starts-with-empty-volumes)).
- Terraform state after a disk replacement:
  [rebuild.md](../rebuild.md#5-terraform-state-after-a-disk-replacement).
- Applying Terraform and playbooks:
  [playbooks-and-terraform.md](playbooks-and-terraform.md).
