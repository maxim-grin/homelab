#!/usr/bin/env bash
# Keep docs/runbooks/ honest. Fails when
#   - a file in ansible/playbooks/ is not named in
#     docs/runbooks/playbooks-and-terraform.md,
#   - a fenced ansible-playbook command names a playbook or an -i inventory
#     that does not exist (commands run from ansible/),
#   - a relative markdown link in docs/runbooks/*.md does not resolve.
# Prose outside fenced blocks is not checked for playbook names.
#
# Usage: scripts/check-runbooks.sh [root]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$HERE/..}"
RUNBOOKS="$ROOT/docs/runbooks"
ANSIBLE="$ROOT/ansible"
INDEX="$RUNBOOKS/playbooks-and-terraform.md"

status=0
fail() {
  echo "$1: $2"
  status=1
}

shopt -s nullglob
docs=("$RUNBOOKS"/*.md)

# (a) every playbook is named in the index.
for pb in "$ANSIBLE"/playbooks/*; do
  [ -f "$pb" ] || continue
  name="$(basename "$pb")"
  if [ ! -f "$INDEX" ] || ! grep -qF -- "$name" "$INDEX"; then
    fail "$INDEX" "playbook $name is not listed"
  fi
done

# (b) fenced ansible-playbook commands. Prints "kind<TAB>path" per reference,
# after joining backslash continuations inside fences.
commands() {
  awk '
    /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
    !infence { next }
    {
      line = $0
      while (line ~ /\\[[:space:]]*$/ && (getline nxt) > 0) {
        sub(/\\[[:space:]]*$/, "", line)
        line = line " " nxt
      }
      if (line !~ /ansible-playbook/) next
      n = split(line, w, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (w[i] == "-i" || w[i] == "--inventory") { print "inv\t" w[i + 1]; i++ }
        else if (w[i] ~ /^--inventory=/) { v = w[i]; sub(/^--inventory=/, "", v); print "inv\t" v }
        else if (w[i] ~ /^-e$|^--extra-vars$/) i++
        else if (w[i] ~ /\.ya?ml$/ && w[i] !~ /^@/) print "pb\t" w[i]
      }
    }
  ' "$1"
}

for doc in "${docs[@]}"; do
  while IFS=$'\t' read -r kind path; do
    [ -n "$path" ] || continue
    path="${path//[\"\']/}"
    if [ "$kind" = pb ]; then
      [ -f "$ANSIBLE/$path" ] || fail "$doc" "playbook $path does not exist"
    else
      [ -e "$ANSIBLE/$path" ] || fail "$doc" "inventory $path does not exist"
    fi
  done < <(commands "$doc")
done

# (c) relative markdown links resolve.
for doc in "${docs[@]}"; do
  while IFS= read -r target; do
    case "$target" in
      http://* | https://* | mailto:* | '#'* | '') continue ;;
    esac
    target="${target%%#*}"
    [ -n "$target" ] || continue
    [ -e "$(dirname "$doc")/$target" ] || fail "$doc" "broken link $target"
  done < <(grep -o '\]([^)]*)' "$doc" | sed 's/^](//; s/)$//' || true)
done

exit "$status"
