#!/usr/bin/env bash
# Managed by ansible (roles/vault). Run by vault-snapshot.service, which
# reads /etc/vault.d/snapshot.env. Saves one raft snapshot to the backups
# share on nfs-01 and keeps the newest VAULT_SNAPSHOT_KEEP.
set -euo pipefail

: "${VAULT_SNAPSHOT_DIR:?}" "${VAULT_SNAPSHOT_KEEP:?}" "${VAULT_ROLE_ID:?}" "${VAULT_SECRET_ID:?}"

# The share is mounted nofail: vault-02 boots before nfs-01, so at boot the
# mount may simply not be there. Try once, then refuse -- a snapshot
# written into the empty local directory would report success and protect
# nothing.
if ! mountpoint -q "$VAULT_SNAPSHOT_DIR"; then
  mount "$VAULT_SNAPSHOT_DIR" 2>/dev/null || true
fi
if ! mountpoint -q "$VAULT_SNAPSHOT_DIR"; then
  echo "vault-snapshot: $VAULT_SNAPSHOT_DIR is not mounted; refusing to write a snapshot to the local disk" >&2
  exit 1
fi

# secret_id over stdin, so it never appears in the process list.
VAULT_TOKEN="$(printf '%s' "$VAULT_SECRET_ID" |
  vault write -field=token auth/approle/login role_id="$VAULT_ROLE_ID" secret_id=-)"
export VAULT_TOKEN

name="vault-$(date -u +%Y%m%dT%H%M%SZ).snap"
# Also clean up a partial file left by a failed `raft snapshot save` -- the
# prune below only ever matches finished `.snap` names, so a `.partial`
# left on the share would otherwise sit there forever.
trap 'rm -f -- "$VAULT_SNAPSHOT_DIR/$name.partial"; vault token revoke -self >/dev/null 2>&1 || true' EXIT
vault operator raft snapshot save "$VAULT_SNAPSHOT_DIR/$name.partial"
mv "$VAULT_SNAPSHOT_DIR/$name.partial" "$VAULT_SNAPSHOT_DIR/$name"
echo "vault-snapshot: saved $name"

# Names sort by time. Everything past the newest KEEP goes.
find "$VAULT_SNAPSHOT_DIR" -maxdepth 1 -name 'vault-*.snap' -printf '%f\n' |
  sort -r | tail -n +"$((VAULT_SNAPSHOT_KEEP + 1))" |
  while read -r old; do
    rm -f -- "$VAULT_SNAPSHOT_DIR/$old"
    echo "vault-snapshot: pruned $old"
  done
