#!/usr/bin/env bash
# Tests for argocd/apps/directive-copilot/base/backup.sh with pg_dump,
# pg_restore and date faked on PATH. Each fake records its argv in
# $S/calls.log, so no database is needed.
#
# Run: bash scripts/tests/directive-copilot-backup.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../argocd/apps/directive-copilot/base/backup.sh"
ORIG_PATH="$PATH"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

OUT=""
RC=0
S=""
D="" # the backup directory of the current case

fail() { printf '    %s\n' "$*" >&2; exit 1; }

make_stubs() {
  local d="$1"
  cat > "$d/pg_dump" <<'STUB'
#!/usr/bin/env bash
echo "pg_dump $*" >> "$S/calls.log"
out=""; prev=""
for a in "$@"; do [ "$prev" = -f ] && out="$a"; prev="$a"; done
# bytes land before the exit status, as with a dump that dies half way
echo new-dump > "$out"
exit "${STUB_DUMP_RC:-0}"
STUB
  cat > "$d/pg_restore" <<'STUB'
#!/usr/bin/env bash
echo "pg_restore $*" >> "$S/calls.log"
exit "${STUB_RESTORE_RC:-0}"
STUB
  cat > "$d/date" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_STAMP:-}" ]; then echo "$STUB_STAMP"; else PATH="$REAL_PATH" exec date "$@"; fi
STUB
  chmod +x "$d"/pg_dump "$d"/pg_restore "$d"/date
}

new_env() {
  local root
  root="$(mktemp -d "$TMP_ROOT/env.XXXXXX")"
  S="$root/state"
  D="$root/backup"
  mkdir -p "$S" "$D" "$root/bin"
  : > "$S/calls.log"
  export S
  make_stubs "$root/bin"
  export REAL_PATH="$ORIG_PATH"
  export PATH="$root/bin:$ORIG_PATH"
  export BACKUP_DIR="$D"
  unset STUB_STAMP STUB_DUMP_RC STUB_RESTORE_RC
  # a script that fails to change directory must not write into the checkout
  cd "$root" || exit 1
}

# old_dumps N: N dumps from January 2026, one per day, oldest first.
old_dumps() {
  local i
  for ((i = 1; i <= $1; i++)); do
    printf 'old-%02d\n' "$i" > "$D/$(old_name "$i")"
  done
}
old_name() { printf 'copilot-202601%02dT090000Z.dump' "$1"; }

run() {
  OUT="$("$SCRIPT" 2>&1)"
  RC=$?
}

assert_ok() { [ "$RC" -eq 0 ] || fail "expected rc 0, got $RC; output: $OUT"; }
# 126 and 127 mean the script never ran, which is not the failure under test
assert_failed() {
  case "$RC" in 0 | 126 | 127) fail "expected the script to fail, got rc $RC; output: $OUT" ;; esac
}
assert_called() { grep -q "^$1 " "$S/calls.log" || fail "$1 never ran; output: $OUT"; }
assert_file() { [ -e "$D/$1" ] || fail "missing $1; have: $(ls -A "$D")"; }
assert_out_contains() {
  case "$OUT" in *"$1"*) ;; *) fail "output lacks '$1'; output: $OUT" ;; esac
}
assert_no_file() { [ ! -e "$D/$1" ] || fail "unexpected $1"; }
# assert_count GLOB N
assert_count() {
  local n
  n="$(find "$D" -maxdepth 1 -name "$1" | wc -l)"
  [ "$n" -eq "$2" ] || fail "expected $2 of $1, got $n: $(ls -A "$D")"
}
# the 15 old dumps survived and nothing new or half-written is left behind
assert_untouched() {
  local i
  for ((i = 1; i <= 15; i++)); do assert_file "$(old_name "$i")"; done
  assert_count '*.dump' 15
  assert_count '*.partial' 0
}

# ---- cases -----------------------------------------------------------------

test_success_keeps_the_14_newest_dumps() {
  old_dumps 15
  STUB_STAMP=20260201T090000Z run
  assert_ok
  assert_count '*.dump' 14
  assert_file copilot-20260201T090000Z.dump
  assert_no_file "$(old_name 1)"
  assert_no_file "$(old_name 2)"
  assert_file "$(old_name 3)"
  assert_count '*.partial' 0
}

test_fewer_than_14_dumps_are_all_kept() {
  old_dumps 3
  run
  assert_ok
  assert_count '*.dump' 4
}

test_the_new_dump_is_named_by_utc_time() {
  run
  assert_ok
  assert_count 'copilot-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.dump' 1
}

test_the_partial_is_dumped_in_custom_format_and_checked_before_rename() {
  STUB_STAMP=20260201T090000Z run
  assert_ok
  grep -qx 'pg_dump -Fc -f copilot-20260201T090000Z.dump.partial' "$S/calls.log" \
    || fail "pg_dump call: $(cat "$S/calls.log")"
  grep -qx 'pg_restore --list copilot-20260201T090000Z.dump.partial' "$S/calls.log" \
    || fail "pg_restore call: $(cat "$S/calls.log")"
}

test_failed_pg_dump_prunes_nothing() {
  old_dumps 15
  STUB_DUMP_RC=1 run
  assert_failed
  assert_called pg_dump
  assert_untouched
}

test_failed_pg_restore_prunes_nothing() {
  old_dumps 15
  STUB_RESTORE_RC=1 run
  assert_failed
  assert_called pg_restore
  assert_untouched
}

test_stale_partial_is_removed_only_after_a_success() {
  local stale=copilot-20250101T090000Z.dump.partial
  old_dumps 15
  echo half > "$D/$stale"
  touch -d '2 days ago' "$D/$stale"
  STUB_DUMP_RC=1 run
  assert_failed
  assert_file "$stale"
  run
  assert_ok
  assert_no_file "$stale"
  assert_count '*.dump' 14
}

test_recent_partial_of_another_run_is_left_alone() {
  echo half > "$D/copilot-20250101T090000Z.dump.partial"
  run
  assert_ok
  assert_file copilot-20250101T090000Z.dump.partial
}

test_second_dump_in_the_same_second_does_not_overwrite() {
  old_dumps 15
  echo first > "$D/copilot-20260201T090000Z.dump"
  STUB_STAMP=20260201T090000Z run
  assert_failed
  [ "$(cat "$D/copilot-20260201T090000Z.dump")" = first ] || fail "first dump overwritten"
  assert_count '*.dump' 16
  assert_count '*.partial' 0
}

test_a_running_dump_with_the_same_name_is_not_clobbered() {
  old_dumps 15
  echo theirs > "$D/copilot-20260201T090000Z.dump.partial"
  STUB_STAMP=20260201T090000Z run
  assert_failed
  [ "$(cat "$D/copilot-20260201T090000Z.dump.partial")" = theirs ] \
    || fail "the other run's partial was touched"
  assert_count '*.dump' 15
}

test_files_the_script_did_not_write_are_neither_counted_nor_removed() {
  local f
  old_dumps 15
  # sorting both before and after the script's own names
  for f in a-before-upgrade.dump z-before-upgrade.dump copilot-manual.dump notes.txt .hidden; do
    echo keep > "$D/$f"
  done
  mkdir "$D/lost+found"
  run
  assert_ok
  for f in a-before-upgrade.dump z-before-upgrade.dump copilot-manual.dump notes.txt .hidden lost+found; do
    assert_file "$f"
  done
  assert_count 'copilot-2*.dump' 14
}

test_clock_set_back_never_removes_the_new_dump() {
  old_dumps 15
  STUB_STAMP=20200101T000000Z run
  assert_ok
  assert_file copilot-20200101T000000Z.dump
}

test_empty_or_unset_backup_dir_means_slash_backup() {
  # never run against a real /backup
  [ ! -e /backup ] || { echo "    skipped: /backup exists here" >&2; return 0; }
  old_dumps 15
  cd "$D" || fail "cd $D"
  BACKUP_DIR="" run
  assert_failed
  assert_out_contains /backup
  unset BACKUP_DIR
  run
  assert_failed
  assert_out_contains /backup
  assert_untouched
  [ ! -s "$S/calls.log" ] || fail "database tools ran: $(cat "$S/calls.log")"
}

test_missing_backup_dir_fails_without_creating_it() {
  BACKUP_DIR="$D/nope" run
  assert_failed
  assert_no_file nope
  [ ! -s "$S/calls.log" ] || fail "database tools ran: $(cat "$S/calls.log")"
}

# ---- runner ----------------------------------------------------------------

passed=0
failed=0
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  new_env
  if ( "$t" ); then
    printf 'ok   %s\n' "$t"
    passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$t"
    failed=$((failed + 1))
  fi
done
printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
