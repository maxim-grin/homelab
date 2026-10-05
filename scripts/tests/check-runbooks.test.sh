#!/usr/bin/env bash
# Tests for scripts/check-runbooks.sh against the fake trees in
# scripts/tests/fixtures/runbooks/.
#
# Run: bash scripts/tests/check-runbooks.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/../check-runbooks.sh"
FIX="$HERE/fixtures/runbooks"
PASS=0
FAIL=0

# expect NAME RC PATTERN: run the guard on fixture NAME, assert exit code RC
# and, when PATTERN is not empty, that the output matches it.
expect() {
  local name="$1" want_rc="$2" pattern="$3" out rc=0
  out="$("$GUARD" "$FIX/$name" 2>&1)" || rc=$?
  if [ "$rc" -eq "$want_rc" ] && { [ -z "$pattern" ] || grep -q -- "$pattern" <<<"$out"; }; then
    PASS=$((PASS + 1))
    echo "ok   $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $name: rc=$rc (want $want_rc), pattern '$pattern'"
    printf '     %s\n' "${out//$'\n'/$'\n     '}"
  fi
}

expect ok 0 ''
expect unlisted-playbook 1 'extra.yaml'
expect missing-playbook 1 'playbooks/gone.yaml'
expect missing-inventory 1 'inventories/nope'
expect broken-link 1 '../nothere.md'

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
