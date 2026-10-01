#!/usr/bin/env bash
# Tests for scripts/pve-bootstrap.sh. Every PVE command is a stub in
# scripts/tests/stubs/ that records its command line in $S/calls.log and keeps
# its state under $S, so no Proxmox host is needed.
#
# Run: bash scripts/tests/pve-bootstrap.test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../pve-bootstrap.sh"
STUBS="$HERE/stubs"
FAKE_TOKEN="11111111-2222-3333-4444-555555555555"
ORIG_PATH="$PATH"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

OUT=""
RC=0

# ---- harness ---------------------------------------------------------------

new_env() {
  local root
  root="$(mktemp -d "$TMP_ROOT/env.XXXXXX")"
  S="$root/state"
  mkdir -p "$S" "$root/apt" "$root/cache" "$root/iso"
  : > "$S/calls.log"
  export S
  export PATH="$STUBS:$ORIG_PATH"
  export APT_SOURCES_DIR="$root/apt"
  export CACHE_DIR="$root/cache"
  export ISO_DIR="$root/iso"
  export ADMIN_USER=opuser
  printf 'Types: deb\nURIs: https://enterprise.proxmox.com/debian/pve\n' \
    > "$APT_SOURCES_DIR/pve-enterprise.sources"
  local v
  for v in $(compgen -v STUB_); do unset "$v"; done
}

run_script() {
  OUT="$(printf 'secretpw\nsecretpw\n' | bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

reset_calls() { : > "$S/calls.log"; }

fail() { printf '    %s\n' "$*" >&2; exit 1; }

assert_rc() { [ "$RC" -eq "$1" ] || fail "expected rc $1, got $RC; output: $OUT"; }
assert_rc_nonzero() { [ "$RC" -ne 0 ] || fail "expected non-zero rc; output: $OUT"; }
assert_calls_contain() {
  grep -Eq -- "$1" "$S/calls.log" || fail "calls.log lacks /$1/"
}
assert_calls_lack() {
  ! grep -Eq -- "$1" "$S/calls.log" || fail "calls.log unexpectedly has /$1/"
}
assert_out_contains() {
  case "$OUT" in *"$1"*) ;; *) fail "output lacks '$1'; output: $OUT" ;; esac
}
assert_out_lacks() {
  case "$OUT" in *"$1"*) fail "output unexpectedly has '$1'" ;; *) ;; esac
}

# ---- cases -----------------------------------------------------------------

test_default_dirs() {
  # grep the settings block: the tests override these dirs, so only the
  # source text can prove the defaults
  grep -Fq 'APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"' "$SCRIPT" || fail "APT_SOURCES_DIR default wrong"
  grep -Fq 'CACHE_DIR="${CACHE_DIR:-/var/lib/vz/template/cache}"' "$SCRIPT" || fail "CACHE_DIR default wrong"
  grep -Fq 'ISO_DIR="${ISO_DIR:-/var/lib/vz/template/iso}"' "$SCRIPT" || fail "ISO_DIR default wrong"
}

test_unknown_step() {
  run_script nosuchstep
  assert_rc_nonzero
  assert_out_contains "unknown step"
}

test_not_root() {
  export STUB_UID=1000
  run_script repos
  assert_rc_nonzero
  assert_out_contains "must run as root"
}

test_dry_run_changes_nothing() {
  run_script --dry-run repos users pools lxc-template
  assert_rc 0
  assert_calls_lack 'pveum (user add|role add|pool add|aclmod)'
  assert_calls_lack 'pveam download'
  assert_calls_lack 'useradd'
  assert_calls_lack 'chpasswd'
  assert_calls_lack 'apt-get'
  assert_calls_lack '^apt update'
  assert_out_contains "+ "
  [ ! -e "$APT_SOURCES_DIR/pve-no-subscription.sources" ] || fail "no-subscription file written in dry run"
  ! grep -q 'Enabled' "$APT_SOURCES_DIR/pve-enterprise.sources" || fail "enterprise file modified in dry run"
}

test_repos_first_run() {
  run_script repos
  assert_rc 0
  grep -q '^Enabled: false$' "$APT_SOURCES_DIR/pve-enterprise.sources" || fail "enterprise not disabled"
  grep -q 'pve-no-subscription' "$APT_SOURCES_DIR/pve-no-subscription.sources" || fail "no-subscription file missing"
  assert_calls_contain 'apt update'
}

test_repos_second_run() {
  run_script repos
  assert_rc 0
  reset_calls
  run_script repos
  assert_rc 0
  assert_calls_lack 'apt update'
}

test_users_first_run() {
  run_script users
  assert_rc 0
  assert_calls_contain 'pveum user add terraform@pve'
  assert_calls_contain 'pveum role add TerraformProv'
  assert_calls_contain 'pveum aclmod / -user terraform@pve -role TerraformProv'
  assert_calls_contain 'pveum user token add terraform@pve terraform --privsep 0'
  assert_calls_contain 'useradd'
  assert_calls_contain 'pveum user add opuser@pam'
  assert_calls_contain 'pveum aclmod / -user opuser@pam -role Administrator'
  assert_out_contains "$FAKE_TOKEN"
  assert_calls_lack '--password'
}

test_no_password_leak() {
  run_script users
  assert_rc 0
  assert_calls_lack 'secretpw'
  assert_out_lacks "secretpw"
  [ -f "$S/chpasswd.log" ] || fail "chpasswd was not called"
  ! grep -q 'secretpw' "$S/chpasswd.log" || fail "password in chpasswd.log"
}

test_token_exists() {
  mkdir -p "$S/users" "$S/tokens" "$S/linux_users"
  touch "$S/users/terraform@pve" "$S/users/opuser@pam" \
    "$S/tokens/terraform@pve!terraform" "$S/linux_users/opuser"
  run_script users
  assert_rc 0
  assert_calls_lack 'user token add'
  assert_out_lacks "$FAKE_TOKEN"
  assert_out_contains "already exists"
}

test_pools_idempotent() {
  local p
  run_script pools
  assert_rc 0
  for p in VM Ubuntu-K8s LXC Talos-K8s; do
    assert_calls_contain "pveum pool add $p\$"
    assert_calls_contain "pveum aclmod /pool/$p -user terraform@pve -role TerraformProv"
  done
  reset_calls
  run_script pools
  assert_rc 0
  assert_calls_lack 'pveum pool add'
  assert_calls_lack 'pveum aclmod'
}

test_lxc_template() {
  local name=debian-13-standard_13.1-2_amd64.tar.zst
  run_script lxc-template
  assert_rc 0
  assert_calls_contain "pveam download local $name"
  assert_calls_lack 'debian-13-standard_13.0-1'
  assert_out_contains "local:vztmpl/$name"
  reset_calls
  run_script lxc-template
  assert_rc 0
  assert_calls_lack 'pveam download'
}

# ---- runner ----------------------------------------------------------------

passed=0
failed=0
for t in $(compgen -A function test_); do
  if ( new_env; "$t" ) > "$TMP_ROOT/case.log" 2>&1; then
    echo "ok   ${t#test_}"
    passed=$((passed + 1))
  else
    echo "FAIL ${t#test_}"
    sed 's/^/    /' "$TMP_ROOT/case.log" | head -8
    failed=$((failed + 1))
  fi
done
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
