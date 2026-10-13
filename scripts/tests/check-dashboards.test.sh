#!/usr/bin/env bash
# Tests for scripts/check-dashboards.sh against the miniature repo tree in
# scripts/tests/fixtures/dashboards/good, copied and broken one way per case.
#
# Needs on PATH: the tools check-dashboards.sh needs.
# Run: bash scripts/tests/check-dashboards.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../check-dashboards.sh"
GOOD="$HERE/fixtures/dashboards/good"
PASS=0
FAIL=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

PROD=argocd/apps/grafana-dashboards/prod

# expect NAME RC PATTERN [ROOT]: run the check on ROOT (default: the
# fixture NAME in $work), assert exit code RC and, when PATTERN is not
# empty, that the output matches it.
expect() {
  local name="$1" want_rc="$2" pattern="$3" root="${4:-$work/$1}" out rc=0
  out="$(DASHBOARDS_ROOT="$root" "$CHECK" 2>&1)" || rc=$?
  if [ "$rc" -eq "$want_rc" ] && { [ -z "$pattern" ] || grep -q -- "$pattern" <<<"$out"; }; then
    PASS=$((PASS + 1))
    echo "ok   $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $name: rc=$rc (want $want_rc), pattern '$pattern'"
    printf '     %s\n' "${out//$'\n'/$'\n     '}"
  fi
}

# fixture NAME: a fresh copy of the good tree.
fixture() {
  cp -r "$GOOD" "$work/$1"
}

fixture good
expect good 0 'dashboards ok'

fixture stale
cat > "$work/stale/dashboards/src/a.jsonnet" <<'JS'
local panel = import 'panel.libsonnet';

{
  uid: 'fixture-a',
  title: 'Fixture a, retitled',
  panels: [panel.stat('Up')],
}
JS
expect stale 1 'differs from dashboards/src/a.jsonnet'

fixture hand-edited
sed -i 's/"Up"/"Down"/' "$work/hand-edited/$PROD/b.json"
expect hand-edited 1 'differs from dashboards/src/b.jsonnet'

fixture no-json
rm "$work/no-json/$PROD/b.json"
expect no-json 1 'has no argocd/apps/grafana-dashboards/prod/b.json'

fixture no-src
cp "$work/no-src/$PROD/a.json" "$work/no-src/$PROD/c.json"
expect no-src 1 'c.json has no dashboards/src/c.jsonnet'

# b renders the same uid as a; its JSON is re-rendered so only the
# duplicate is wrong.
fixture dup-uid
sed -i "s/fixture-b/fixture-a/" "$work/dup-uid/dashboards/src/b.jsonnet"
(cd "$work/dup-uid" && DASHBOARDS_ROOT="$PWD" "$CHECK" --write >/dev/null 2>&1)
expect dup-uid 1 'duplicate dashboard uid: fixture-a'

fixture not-in-kustomization
sed -i '/dashboard-b/,$d' "$work/not-in-kustomization/$PROD/kustomization.yaml"
expect not-in-kustomization 1 'b.json is not listed'

fixture unformatted
printf '{uid:"fixture-a",title:"x"}\n' > "$work/unformatted/dashboards/src/a.jsonnet"
expect unformatted 1 'not jsonnetfmt-clean'

# --write repairs a stale tree.
fixture write
sed -i 's/"Up"/"Down"/' "$work/write/$PROD/b.json"
(cd "$work/write" && DASHBOARDS_ROOT="$PWD" "$CHECK" --write >/dev/null 2>&1)
expect write 0 'dashboards ok'

# Before any dashboard exists: no sources, no app directory.
mkdir -p "$work/empty/dashboards/src"
expect empty 0 'skipped'

# A PATH with none of the tools.
rc=0
out="$(PATH="$work/empty" DASHBOARDS_ROOT="$work/good" /bin/bash "$CHECK" 2>&1)" || rc=$?
if [ "$rc" -eq 2 ] && grep -q 'missing tool' <<<"$out"; then
  PASS=$((PASS + 1))
  echo "ok   missing-tool"
else
  FAIL=$((FAIL + 1))
  echo "FAIL missing-tool: rc=$rc $out"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
