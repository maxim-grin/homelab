#!/usr/bin/env bash
# Tests for scripts/check-appsets.sh against the miniature repo trees in
# scripts/tests/fixtures/appsets/.
#
# Run: bash scripts/tests/check-appsets.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/../check-appsets.sh"
FIX="$HERE/fixtures/appsets"
PASS=0
FAIL=0

# expect NAME RC PATTERN: run the check on fixture NAME, assert exit code RC
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

expect good 0 'prod-nfs-provisioner'
expect underscore 1 'not a valid DNS-1123 label'
expect capital 1 'not a valid DNS-1123 label'
expect no-cluster 1 'no cluster Secret provides'
expect misplaced-key 1 'misplaced key'
expect bad-destination 1 'not allowed by'
expect noconfig 1 'references no config'

# A tree with no set at all is skipped, not failed.
empty="$(mktemp -d)"
trap 'rm -rf "$empty"' EXIT
rc=0
out="$("$GUARD" "$empty" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && grep -q skipped <<<"$out"; then
  PASS=$((PASS + 1))
  echo "ok   no-set"
else
  FAIL=$((FAIL + 1))
  echo "FAIL no-set: rc=$rc $out"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
