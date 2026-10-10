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
[Restore jobboard's database on dev](#restore-jobboards-database-on-dev),
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

When: a bad Vault upgrade, a deleted or overwritten secret, or a fresh
`vault-02` after a rebuild.

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
export VAULT_ADDR=https://10.0.0.133:8200
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
| The Vault unseal key and root token | Without them Vault stays sealed and no snapshot can be restored. |

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

## Rebuild pointers

- Whole rebuild, in order: [rebuild.md](../rebuild.md#rebuild-order).
- Dev only: [rebuild.md](../rebuild.md#rebuilding-dev-only); the new cluster
  starts with empty volumes
  ([rebuild.md](../rebuild.md#the-new-cluster-starts-with-empty-volumes)).
- Terraform state after a disk replacement:
  [rebuild.md](../rebuild.md#5-terraform-state-after-a-disk-replacement).
- Applying Terraform and playbooks:
  [playbooks-and-terraform.md](playbooks-and-terraform.md).
