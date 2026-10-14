#!/usr/bin/env bash
# Check that every Grafana dashboard rendered from jsonnet is committed
# exactly as the source renders it: dashboards/src/<n>.jsonnet must equal
# argocd/apps/grafana-dashboards/prod/<n>.json, no JSON may exist without
# a source, uids must be unique, and every dashboard must be listed in the
# app's kustomization. Runs in CI (the `dashboards` job) and locally.
#
#   scripts/check-dashboards.sh           compare; exit 1 on any drift
#   scripts/check-dashboards.sh --write   render in place instead; skips the
#                                         orphan, uid and kustomization checks
#
# Exit codes: 0 clean, 1 drift or a broken source, 2 missing tool.
# DASHBOARDS_ROOT overrides the repository root (the tests use it).
#
# Needs on PATH: jsonnet, jsonnetfmt, jb, kustomize, yq (mikefarah v4).
set -euo pipefail

write=0
case "${1:-}" in
  "") ;;
  --write) write=1 ;;
  *) echo "usage: $0 [--write]" >&2; exit 2 ;;
esac

for tool in jsonnet jsonnetfmt jb kustomize yq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done

root="${DASHBOARDS_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$root"

src=dashboards/src
out=argocd/apps/grafana-dashboards/prod

shopt -s nullglob
sources=("$src"/*.jsonnet)
shopt -u nullglob

# Before the first dashboard exists there is nothing to check.
if [ "${#sources[@]}" -eq 0 ] && [ ! -d argocd/apps/grafana-dashboards ]; then
  echo "no dashboards: skipped"
  exit 0
fi

failed=0
fail() {
  echo "FAIL: $*" >&2
  failed=1
}

# Vendored libraries (Grafonnet) come from the lock file.
if [ -f dashboards/jsonnetfile.json ]; then
  (cd dashboards && jb install)
fi

include=()
for d in dashboards/vendor dashboards/lib; do
  [ -d "$d" ] && include+=(-J "$d")
done

echo "== jsonnetfmt"
while IFS= read -r f; do
  jsonnetfmt --test "$f" || fail "$f is not jsonnetfmt-clean (run jsonnetfmt -i)"
done < <(find dashboards -path dashboards/vendor -prune -o \( -name '*.jsonnet' -o -name '*.libsonnet' \) -print | sort)

echo "== render"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
for s in ${sources[@]+"${sources[@]}"}; do
  n=$(basename "$s" .jsonnet)
  # jsonnet emits keys sorted, three-space indented: stable diffs.
  if ! jsonnet ${include[@]+"${include[@]}"} "$s" > "$work/$n.json"; then
    fail "jsonnet failed to render $s"
    continue
  fi
  if [ "$write" -eq 1 ]; then
    cp "$work/$n.json" "$out/$n.json"
    echo "wrote $out/$n.json"
  elif [ ! -f "$out/$n.json" ]; then
    fail "$s has no $out/$n.json (run $0 --write)"
  elif ! diff -u "$out/$n.json" "$work/$n.json" >&2; then
    fail "$out/$n.json differs from $s (run $0 --write)"
  fi
done

[ "$write" -eq 0 ] || exit "$failed"

echo "== orphans and uids"
for j in "$out"/*.json; do
  [ -e "$j" ] || continue
  n=$(basename "$j" .json)
  [ -f "$src/$n.jsonnet" ] || fail "$j has no $src/$n.jsonnet"
done
dups=$(for j in "$out"/*.json; do
  if [ -e "$j" ]; then yq -r '.uid' "$j"; fi
done | sort | uniq -d)
[ -z "$dups" ] || fail "duplicate dashboard uid: $(echo "$dups" | tr '\n' ' ')"

echo "== kustomization"
if [ -f "$out/kustomization.yaml" ]; then
  listed=$(yq -r '.configMapGenerator[]?.files[]?' "$out/kustomization.yaml" | sed 's/^.*=//')
  for s in ${sources[@]+"${sources[@]}"}; do
    n=$(basename "$s" .jsonnet)
    grep -qxF "$n.json" <<<"$listed" || fail "$n.json is not listed in $out/kustomization.yaml"
  done
  kustomize build "$out" >/dev/null || fail "kustomize build $out"
elif [ "${#sources[@]}" -gt 0 ]; then
  fail "$out/kustomization.yaml is missing"
fi

[ "$failed" -eq 0 ] && echo "dashboards ok"
exit "$failed"
