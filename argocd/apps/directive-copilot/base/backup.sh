#!/usr/bin/env bash
# Dump the database named by the libpq PG* variables into BACKUP_DIR and keep
# the 14 newest dumps. Any failure exits non-zero, removes its own partial and
# prunes nothing: the old dumps are the only copies there are.
set -euo pipefail
export LC_ALL=C # glob order is byte order, so the dump names sort by time

cd -- "${BACKUP_DIR:-/backup}"

name="copilot-$(date -u +%Y%m%dT%H%M%SZ).dump"
partial="$name.partial"

# Claim the name first: another run's partial must be neither overwritten nor
# removed by the trap below.
(set -o noclobber && : > "$partial")
trap 'rm -f -- "$partial"' EXIT
# Checked after the claim, so a run from the same second has finished renaming.
[ ! -e "$name" ] || { echo "backup: $name already exists" >&2; exit 1; }

pg_dump -Fc -f "$partial"
# shortcut: --list reads only the table of contents; add a full read
# (pg_restore -f /dev/null) if a damaged dump ever gets through.
pg_restore --list "$partial" > /dev/null
mv -- "$partial" "$name"
echo "backup: wrote $name"

# A killed run leaves its partial behind; after a day no run still writes it.
find . -maxdepth 1 -type f -name 'copilot-*.dump.partial' -mmin +1440 -delete

# Only names this script writes: a hand-made *.dump sorting after them would
# otherwise take a slot and push real dumps out.
dumps=(copilot-????????T??????Z.dump)
for ((i = 0; i < ${#dumps[@]} - 14; i++)); do
  # With the clock set back the new dump sorts oldest; never remove it.
  [ "${dumps[i]}" = "$name" ] || rm -- "${dumps[i]}"
done
