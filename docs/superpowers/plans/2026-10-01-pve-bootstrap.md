# Proxmox Host Bootstrap Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One idempotent bash script takes a fresh Proxmox VE 9 host to the state `terraform apply` assumes, with stub tests in CI.

**Architecture:** `scripts/pve-bootstrap.sh` is standalone (no repo checkout needed on `pve`). Every mutating command goes through a `run` wrapper (`--dry-run` prints instead). Each step checks state, acts, verifies. Tests run the real script against fake `qm`/`pveum`/`pveam`/... binaries on `PATH`, backed by a state dir.

**Tech Stack:** bash 5, shellcheck (via `shellcheck-py` pre-commit hook), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-01-pve-bootstrap-design.md` (read it first; this plan implements it).

## Global Constraints

- Work only in worktree `/home/ubuntu/homelab/.worktrees/pve-bootstrap`, branch `pve-bootstrap`. Never switch branches in `/home/ubuntu/homelab`, never bare `git stash`, never push (controller pushes).
- No access to Proxmox here. Only the stub tests, `bash -n`, `--dry-run` against stubs, and CI-equivalent commands can run.
- Script: bash, `set -euo pipefail`, `set +x` forced, no file ever contains a secret, no password on a command line or in the environment, never logged.
- Constants verbatim: `TALOS_VERSION` default `v1.14.2`; `TALOS_SCHEMATIC` default `ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515`; `UBUNTU_RELEASE` default `noble`; template vmids 5000 (`ubuntu-cid-tp`) and 5001 (`talos-tp`); pools `VM Ubuntu-K8s LXC Talos-K8s`; role `TerraformProv`; user `terraform@pve`; token id `terraform`, `--privsep 0`; storage `local-lvm`; node `pve`.
- Role privileges verbatim: `VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Monitor VM.Audit VM.PowerMgmt Datastore.AllocateSpace Datastore.Audit`.
- Never destroy or overwrite an existing VM/template; refuse and print the manual line.
- Commits: Conventional Commits, subject <= 50 chars, imperative, lowercase, types `feat fix refactor docs chore ops` only (no `ci`), body wrapped at 72, **no `Co-Authored-By`, no generated-with footer**, never `--no-verify`.
- Prose in docs: "the operator's workstation", never "the Mac"/"the laptop"; no mention of the original author or the old `talos/_out` leak.
- Read narrowly: `grep -n` / `sed -n`, not `cat` of whole files.
- ADR number 0022 (0020 and 0021 are on other branches); renumber at merge if needed.

## Review Focus

1. **Second run changes nothing:** a full run on empty state, then a second run on the resulting state, issues no creating command (Task 2 test `idempotent_second_run`).
2. **Existing token:** never re-created, no secret printed, message says how to rotate (Task 2 test `token_exists`).
3. **Non-template VM at 5000/5001:** step stops non-zero, no `qm create` (Task 2 test `vmid_not_template`).
4. **Corrupt image:** checksum mismatch aborts before `virt-customize` (Task 2 test `bad_checksum`).
5. **Secret leakage:** the generated/typed admin password appears in no stub call log, no stdout/stderr (Task 2 test `no_password_leak`).

---

## File Structure

| Path | Action | Responsibility |
| --- | --- | --- |
| `scripts/pve-bootstrap.sh` | create | the script (Tasks 1-2) |
| `scripts/tests/pve-bootstrap.test.sh` | create | test runner + cases (Tasks 1-2) |
| `scripts/tests/stubs/*` | create | fake binaries (Task 1) |
| `scripts/check-talos-pins.sh` | create | pin drift check (Task 3) |
| `.pre-commit-config.yaml` | modify | shellcheck hook (Task 3) |
| `.github/workflows/ci.yaml` | modify | `scripts` job (Task 3) |
| `docs/rebuild.md`, `CLAUDE.md`, `README.md`, `docs/decisions/0022-*.md`, `docs/decisions/README.md`, spec | modify/create | docs (Task 4) |

---

### Task 1: Script skeleton, stubs, and the first four steps (`repos`, `users`, `pools`, `lxc-template`) — tests first

**Files:**
- Create: `scripts/pve-bootstrap.sh`, `scripts/tests/pve-bootstrap.test.sh`, `scripts/tests/stubs/{pveversion,pveum,pvesh,pveam,qm,apt,apt-get,hostname,id,useradd,usermod,chpasswd,getent,sudo,wget,xz,virt-customize}`

**Interfaces:**
- Produces (used by Task 2): in the script, functions `run`, `note_created`, `note_changed`, `note_skipped`, `die`, `vm_exists ID`, `vm_is_template ID`, and variables `DRY_RUN`, `CACHE_DIR`, `ISO_DIR`, `APT_SOURCES_DIR`, `STORAGE`, `TALOS_VERSION`, `TALOS_SCHEMATIC`, `UBUNTU_RELEASE`, `UBUNTU_TEMPLATE_VMID`, `TALOS_TEMPLATE_VMID`, `POOLS`; step functions named `step_repos`, `step_users`, `step_pools`, `step_lxc_template` (Task 1) and `step_ubuntu_template`, `step_talos_template` (Task 2), dispatched by name from `main`.
- Test harness (used by Task 2): `scripts/tests/pve-bootstrap.test.sh` defines `new_env` (fresh temp dir, sets `S` state dir, `PATH`, env overrides), `run_script ARGS...` (captures `OUT`, `RC`), `assert_rc N`, `assert_calls_contain PATTERN`, `assert_calls_lack PATTERN`, `assert_out_contains TEXT`, `assert_out_lacks TEXT`, `reset_calls`, and registers cases as functions named `test_*`.

**Stub contract (state under `$S`, all stubs append their full argv to `$S/calls.log` first):**
- `pvesh get PATH`: exit 0 if the object exists else 1. Paths: `/access/users/<id>` -> file `$S/users/<id>`; `/access/roles/<n>` -> `$S/roles/<n>`; `/pools/<n>` -> `$S/pools/<n>`; `/access/users/<u>/token/<t>` -> `$S/tokens/<u>!<t>`.
- `pveum user add ID ...` touches `$S/users/ID`; `pveum role add|modify NAME ...` touches/updates `$S/roles/NAME`; `pveum pool add NAME` touches `$S/pools/NAME`; `pveum aclmod PATH -user U -role R` appends `U PATH 1 R user` to `$S/acl`; `pveum acl list ...` prints `$S/acl`; `pveum user token add U T ...` creates `$S/tokens/U!T` and prints a table containing the line `│ value        │ 11111111-2222-3333-4444-555555555555 │`.
- `pveam update` logs; `pveam available --section system` prints `system          debian-12-standard_12.7-1_amd64.tar.zst`, `system          debian-13-standard_13.0-1_amd64.tar.zst`, `system          debian-13-standard_13.1-2_amd64.tar.zst`; `pveam list local` prints names from `$S/pveam/*`; `pveam download local NAME` touches `$S/pveam/NAME`.
- `qm config ID`: exit 2 if `$S/vms/ID` absent else cat it; `qm create ID ...` creates `$S/vms/ID` with `name: <value of --name>`; `qm importdisk ID FILE STORAGE` appends `unused0: STORAGE:vm-ID-disk-0` to the config; `qm set ID ...` removes `unused0:` and appends `scsi0: ...` when `--scsi0` given; `qm template ID` appends `template: 1`.
- `pveversion` prints `pve-manager/9.0.3/abc123 (running kernel: 6.14.8-2-pve)`; `hostname` prints `${STUB_HOSTNAME:-pve}` (and accepts `-s`); `id -u` prints `${STUB_UID:-0}`; `id NAME` exits 0 iff `$S/linux_users/NAME` exists; `useradd`/`usermod` touch/log (`useradd ... NAME` touches `$S/linux_users/NAME`); `chpasswd` reads stdin and appends only the *username* part (never the password) to `$S/chpasswd.log`, and logs `chpasswd` without stdin to calls.log; `getent group sudo` exits 0; `sudo` is only checked with `command -v`; `apt`, `apt-get`, `virt-customize` log only; `wget` writes the `-O` target (or the URL's basename) with content `FAKEIMG`, except for a URL ending `SHA256SUMS` where it writes `<sha256 of "FAKEIMG"> *noble-server-cloudimg-amd64.img` (or a wrong hash when `STUB_BAD_SUM=1`); `xz -d FILE.xz` creates `FILE` with `FAKEIMG` and removes `FILE.xz`.
- Stubs are executable bash scripts using `set -u`, and write only under `$S`.

- [ ] **Step 1: Write the stubs**

Create each file under `scripts/tests/stubs/` as a bash script (`#!/usr/bin/env bash`, `chmod +x`) implementing the contract above. Shared helper: each starts with `printf '%s\n' "$(basename "$0") $*" >> "$S/calls.log"` (the tests export `S`). Example, `scripts/tests/stubs/pvesh`:

```bash
#!/usr/bin/env bash
set -u
printf '%s\n' "pvesh $*" >> "$S/calls.log"
[ "${1:-}" = get ] || exit 0
p=${2:-}
case "$p" in
  /access/users/*/token/*) u=${p#/access/users/}; user=${u%%/*}; tok=${u##*/}; [ -e "$S/tokens/$user!$tok" ] ;;
  /access/users/*) [ -e "$S/users/${p#/access/users/}" ] ;;
  /access/roles/*) [ -e "$S/roles/${p#/access/roles/}" ] ;;
  /pools/*) [ -e "$S/pools/${p#/pools/}" ] ;;
  *) exit 1 ;;
esac
```

and `scripts/tests/stubs/pveum`:

```bash
#!/usr/bin/env bash
set -u
printf '%s\n' "pveum $*" >> "$S/calls.log"
mkdir -p "$S/users" "$S/roles" "$S/pools" "$S/tokens"
case "${1:-} ${2:-}" in
  "user add") touch "$S/users/$3" ;;
  "role add"|"role modify") echo "$*" > "$S/roles/$3" ;;
  "pool add") touch "$S/pools/$3" ;;
  "user token") # user token add U T ...
    touch "$S/tokens/$4!$5"
    printf '%s\n' '┌──────────────┬──────────────────────────────────────┐' \
      '│ key          │ value                                │' \
      '│ full-tokenid │ terraform@pve!terraform              │' \
      '│ value        │ 11111111-2222-3333-4444-555555555555 │' \
      '└──────────────┴──────────────────────────────────────┘' ;;
  "acl list") cat "$S/acl" 2>/dev/null || true ;;
  *) if [ "${1:-}" = aclmod ]; then
       # aclmod PATH -user U -role R
       echo "$4 $2 1 $6 user" >> "$S/acl"
     fi ;;
esac
exit 0
```

Write the remaining stubs the same way (`qm`, `pveam`, `pveversion`, `hostname`, `id`, `useradd`, `usermod`, `chpasswd`, `getent`, `apt`, `apt-get`, `wget`, `xz`, `virt-customize`; `sudo` can be an empty executable). `chpasswd` stub:

```bash
#!/usr/bin/env bash
set -u
printf '%s\n' "chpasswd" >> "$S/calls.log"
while IFS=: read -r name _; do printf '%s\n' "$name" >> "$S/chpasswd.log"; done
```

- [ ] **Step 2: Write the test harness and the first failing tests**

`scripts/tests/pve-bootstrap.test.sh` (`#!/usr/bin/env bash`, `set -u`): resolves `HERE`, `SCRIPT="$HERE/../pve-bootstrap.sh"`; `new_env` makes `T=$(mktemp -d)`, `S=$T/state`, `mkdir -p $S/vms ...`, exports `S`, `PATH="$HERE/stubs:$PATH"`, `APT_SOURCES_DIR=$T/apt`, `CACHE_DIR=$T/cache`, `ISO_DIR=$T/iso`, `ADMIN_USER=opuser`, creates `$APT_SOURCES_DIR` with a `pve-enterprise.sources` containing `Types: deb`, and unsets `STUB_*`. `run_script` runs `printf 'secretpw\nsecretpw\n' | bash "$SCRIPT" "$@"` capturing `OUT` (stdout+stderr) and `RC`. Assertions use `grep -qE` on `$S/calls.log` / `$OUT` and print `ok`/`FAIL name: reason`; a failure increments `FAILS`. The runner calls every function whose name starts with `test_` (via `declare -F`), prints a summary and exits non-zero if `FAILS > 0`. Cases for this task:

```bash
test_unknown_step()       { new_env; run_script nosuchstep;            assert_rc_nonzero; assert_out_contains "unknown step"; }
test_not_root()           { new_env; STUB_UID=1000 run_script repos;    assert_rc_nonzero; assert_out_contains "must run as root"; }
test_dry_run_changes_nothing() {
  new_env; run_script --dry-run repos users pools lxc-template
  assert_rc 0
  assert_calls_lack 'pveum (user add|role add|pool add|aclmod)|pveam download|useradd|chpasswd|^apt update|apt-get'
  assert_out_contains "+ "
  [ ! -e "$APT_SOURCES_DIR/pve-no-subscription.sources" ] || fail "dry-run wrote a file"
}
test_repos_first_run()    { new_env; run_script repos; assert_rc 0
  grep -q 'Enabled: false' "$APT_SOURCES_DIR/pve-enterprise.sources" || fail "enterprise not disabled"
  grep -q 'pve-no-subscription' "$APT_SOURCES_DIR/pve-no-subscription.sources" || fail "no-sub file"
  assert_calls_contain '^apt update' ; }
test_repos_second_run()   { new_env; run_script repos; reset_calls; run_script repos; assert_rc 0; assert_calls_lack '^apt update'; }
test_users_first_run()    { new_env; run_script users; assert_rc 0
  assert_calls_contain 'pveum user add terraform@pve'
  assert_calls_contain 'pveum role add TerraformProv'
  assert_calls_contain 'pveum aclmod / -user terraform@pve -role TerraformProv'
  assert_calls_contain 'pveum user token add terraform@pve terraform --privsep 0'
  assert_out_contains '11111111-2222-3333-4444-555555555555'
  assert_calls_contain 'useradd'; assert_calls_contain 'pveum user add opuser@pam'
  assert_calls_contain 'pveum aclmod / --roles Administrator|pveum aclmod / -user opuser@pam -role Administrator'; }
test_no_password_leak()   { new_env; run_script users
  assert_calls_lack 'secretpw'; assert_out_lacks 'secretpw'; [ ! -e "$S/chpasswd.log" ] || ! grep -q secretpw "$S/chpasswd.log" || fail "password logged"; }
test_token_exists()       { new_env; mkdir -p "$S/users" "$S/tokens"; touch "$S/users/terraform@pve" "$S/tokens/terraform@pve!terraform"
  run_script users; assert_rc 0; assert_calls_lack 'user token add'; assert_out_lacks '11111111-2222'; assert_out_contains 'already exists'; }
test_pools_idempotent()   { new_env; run_script pools; assert_rc 0
  for p in VM Ubuntu-K8s LXC Talos-K8s; do assert_calls_contain "pveum pool add $p"; assert_calls_contain "pveum aclmod /pool/$p -user terraform@pve -role TerraformProv"; done
  reset_calls; run_script pools; assert_rc 0; assert_calls_lack 'pool add|aclmod'; }
test_lxc_template()       { new_env; run_script lxc-template; assert_rc 0
  assert_calls_contain 'pveam download local debian-13-standard_13.1-2_amd64.tar.zst'
  assert_out_contains 'local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst'
  reset_calls; run_script lxc-template; assert_calls_lack 'pveam download'; }
```

Implement `fail`, `assert_rc`, `assert_rc_nonzero`, `assert_calls_contain/lack`, `assert_out_contains/lacks`, `reset_calls` (`: > "$S/calls.log"`) in the harness. The admin password prompt is satisfied by the piped `secretpw` twice.

- [ ] **Step 3: Run tests, expect failure**

Run: `bash scripts/tests/pve-bootstrap.test.sh`
Expected: every `test_*` FAILs ("cannot execute" / script missing). Record the summary line.

- [ ] **Step 4: Write the script (header, helpers, `main`, four steps)**

`scripts/pve-bootstrap.sh`:

```bash
#!/usr/bin/env bash
# Bootstrap a fresh Proxmox VE 9 host for this repository: apt repos, an admin
# user, the terraform@pve user/role/token, resource pools with their ACLs, and
# the three templates Terraform clones. Run as root on the Proxmox host:
#
#   bash pve-bootstrap.sh [--dry-run] [step ...]
#
# Steps: repos users pools lxc-template ubuntu-template talos-template
# (default: all, in that order). Every step checks state first and does
# nothing if it is already right. Secrets are never written to a file or
# logged; the API token secret prints once. See docs/rebuild.md.
set -euo pipefail
set +x

# --- settings (override from the environment) -------------------------------
TALOS_VERSION="${TALOS_VERSION:-v1.14.2}"
TALOS_SCHEMATIC="${TALOS_SCHEMATIC:-ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-noble}"
UBUNTU_TEMPLATE_VMID="${UBUNTU_TEMPLATE_VMID:-5000}"
TALOS_TEMPLATE_VMID="${TALOS_TEMPLATE_VMID:-5001}"
POOLS="${POOLS:-VM Ubuntu-K8s LXC Talos-K8s}"
STORAGE="${STORAGE:-local-lvm}"
TF_USER="terraform@pve"
TF_ROLE="TerraformProv"
TF_TOKEN="terraform"
TF_PRIVS="VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Monitor VM.Audit VM.PowerMgmt Datastore.AllocateSpace Datastore.Audit"
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
CACHE_DIR="${CACHE_DIR:-/var/lib/vz/template/cache}"
ISO_DIR="${ISO_DIR:-/var/lib/vz/template/iso}"
ALL_STEPS="repos users pools lxc-template ubuntu-template talos-template"
DRY_RUN=0
CREATED=(); CHANGED=(); SKIPPED=(); TFVARS=()

# --- helpers ----------------------------------------------------------------
die() { echo "error: $*" >&2; exit 1; }
note_created() { CREATED+=("$*"); }
note_changed() { CHANGED+=("$*"); }
note_skipped() { SKIPPED+=("$*"); }
# Every state-changing command goes through run, so --dry-run can print it.
run() {
  if [ "$DRY_RUN" = 1 ]; then echo "+ $*"; return 0; fi
  "$@"
}
vm_exists()      { qm config "$1" >/dev/null 2>&1; }
vm_is_template() { qm config "$1" 2>/dev/null | grep -q '^template: 1'; }
has_acl() { # has_acl PATH USER ROLE: order-independent match on one row
  pveum acl list --noborder 1 2>/dev/null | awk -v p="$1" -v u="$2" -v r="$3" '
    { fp = fu = fr = 0
      for (i = 1; i <= NF; i++) { if ($i == p) fp = 1; if ($i == u) fu = 1; if ($i == r) fr = 1 }
      if (fp && fu && fr) found = 1 }
    END { exit !found }'
}
ensure_acl() { # ensure_acl PATH USER ROLE
  if has_acl "$1" "$2" "$3"; then note_skipped "acl $1 $2 $3"; return 0; fi
  run pveum aclmod "$1" -user "$2" -role "$3"
  note_created "acl $1 $2 $3"
}

preflight() {
  [ "$(id -u)" -eq 0 ] || die "must run as root"
  command -v pveversion >/dev/null 2>&1 || die "pveversion not found: this is not a Proxmox host"
  local node; node=$(hostname -s 2>/dev/null || hostname)
  [ "$node" = pve ] || echo "warning: node is '$node', every tfvars file assumes 'pve'" >&2
}

# --- steps ------------------------------------------------------------------
step_repos() {
  local ent="$APT_SOURCES_DIR/pve-enterprise.sources" nosub="$APT_SOURCES_DIR/pve-no-subscription.sources" changed=0
  if [ -e "$ent" ] && ! grep -q '^Enabled: false' "$ent"; then
    if [ "$DRY_RUN" = 1 ]; then echo "+ disable $ent"; else
      sed -i '/^Enabled:/d' "$ent"; echo 'Enabled: false' >> "$ent"; fi
    note_changed "pve-enterprise repo disabled"; changed=1
  else note_skipped "pve-enterprise repo already disabled or absent"; fi
  if [ ! -e "$nosub" ]; then
    if [ "$DRY_RUN" = 1 ]; then echo "+ write $nosub"; else
      cat > "$nosub" <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    fi
    note_created "pve-no-subscription repo"; changed=1
  else note_skipped "pve-no-subscription repo"; fi
  if [ "$changed" = 1 ]; then run apt update; fi
}

read_password() { # read_password VARNAME: prompt twice, set the named variable
  local a b
  read -rsp "Password for $ADMIN_USER: " a; echo >&2
  read -rsp "Again: " b; echo >&2
  [ "$a" = "$b" ] || die "passwords differ"
  [ -n "$a" ] || die "empty password"
  printf -v "$1" '%s' "$a"
}

step_users() {
  # Admin user, for SSH and the web UI.
  if [ -z "${ADMIN_USER:-}" ]; then
    if [ -t 0 ]; then read -rp "Admin username (empty to skip): " ADMIN_USER; else ADMIN_USER=""; fi
  fi
  if [ -z "$ADMIN_USER" ]; then
    note_skipped "admin user (ADMIN_USER not set)"
  else
    if id "$ADMIN_USER" >/dev/null 2>&1; then
      note_skipped "linux user $ADMIN_USER"
    else
      local pw; read_password pw
      command -v sudo >/dev/null 2>&1 || run apt-get install -y sudo
      run useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
      if [ "$DRY_RUN" = 1 ]; then echo "+ chpasswd (password from prompt)"; else
        printf '%s:%s\n' "$ADMIN_USER" "$pw" | chpasswd; fi
      unset pw
      note_created "linux user $ADMIN_USER"
    fi
    if pvesh get "/access/users/$ADMIN_USER@pam" >/dev/null 2>&1; then
      note_skipped "pve user $ADMIN_USER@pam"
    else
      run pveum user add "$ADMIN_USER@pam" -comment "$ADMIN_USER admin"
      note_created "pve user $ADMIN_USER@pam"
    fi
    ensure_acl / "$ADMIN_USER@pam" Administrator
  fi

  # Terraform user: no password, only its token is ever used.
  if pvesh get "/access/users/$TF_USER" >/dev/null 2>&1; then
    note_skipped "pve user $TF_USER"
  else
    run pveum user add "$TF_USER" -comment "Terraform"
    note_created "pve user $TF_USER"
  fi
  # shellcheck disable=SC2086 # TF_PRIVS is a word list on purpose
  if pvesh get "/access/roles/$TF_ROLE" >/dev/null 2>&1; then
    run pveum role modify "$TF_ROLE" -privs "$TF_PRIVS"
    note_changed "role $TF_ROLE privileges set"
  else
    run pveum role add "$TF_ROLE" -privs "$TF_PRIVS"
    note_created "role $TF_ROLE"
  fi
  ensure_acl / "$TF_USER" "$TF_ROLE"

  if pvesh get "/access/users/$TF_USER/token/$TF_TOKEN" >/dev/null 2>&1; then
    echo "token $TF_USER!$TF_TOKEN already exists; Proxmox cannot show its secret again." >&2
    echo "to rotate: pveum user token remove $TF_USER $TF_TOKEN, then re-run this step." >&2
    note_skipped "token $TF_USER!$TF_TOKEN (already exists)"
  else
    echo "Creating API token. The secret below is shown once; copy it into pm_api_token_secret."
    run pveum user token add "$TF_USER" "$TF_TOKEN" --privsep 0
    note_created "token $TF_USER!$TF_TOKEN"
  fi
  TFVARS+=("pm_api_token_id = \"$TF_USER!$TF_TOKEN\"")
}

step_pools() {
  local p
  for p in $POOLS; do
    if pvesh get "/pools/$p" >/dev/null 2>&1; then note_skipped "pool $p"
    else run pveum pool add "$p"; note_created "pool $p"; fi
    ensure_acl "/pool/$p" "$TF_USER" "$TF_ROLE"
  done
}

step_lxc_template() {
  local name
  run pveam update
  name=$(pveam available --section system | awk '$2 ~ /^debian-13-standard_/ {print $2}' | sort -V | tail -1)
  [ -n "$name" ] || die "no debian-13-standard template offered by pveam"
  if pveam list local | grep -qF "$name"; then note_skipped "lxc template $name"
  else run pveam download local "$name"; note_created "lxc template $name"; fi
  TFVARS+=("debian_lxc_template = \"local:vztmpl/$name\"")
}

# (Task 2 adds step_ubuntu_template, step_talos_template.)

summary() {
  local x
  echo; echo "== summary =="
  for x in "${CREATED[@]+"${CREATED[@]}"}"; do echo "created: $x"; done
  for x in "${CHANGED[@]+"${CHANGED[@]}"}"; do echo "changed: $x"; done
  for x in "${SKIPPED[@]+"${SKIPPED[@]}"}"; do echo "skipped: $x"; done
  if [ "${#TFVARS[@]}" -gt 0 ]; then
    echo; echo "== values for tfvars =="
    for x in "${TFVARS[@]}"; do echo "$x"; done
  fi
}

main() {
  local steps=() a s
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN=1 ;;
      -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
      *) steps+=("$a") ;;
    esac
  done
  [ "${#steps[@]}" -gt 0 ] || read -ra steps <<<"$ALL_STEPS"
  for s in "${steps[@]}"; do
    case " $ALL_STEPS " in *" $s "*) ;; *) die "unknown step '$s' (steps: $ALL_STEPS)" ;; esac
  done
  preflight
  for s in "${steps[@]}"; do
    echo "== $s =="
    "step_${s//-/_}"
  done
  summary
}
main "$@"
```

- [ ] **Step 5: Run the tests, expect green**

Run: `bash scripts/tests/pve-bootstrap.test.sh`
Expected: all Task 1 cases print `ok`, summary `0 failed`. Also: `bash -n scripts/pve-bootstrap.sh`. If a case fails because the *stub* is wrong, fix the stub; if because the script is wrong, fix the script. Do not weaken an assertion; report any real mismatch.

- [ ] **Step 6: Commit**

```bash
git add scripts/pve-bootstrap.sh scripts/tests
git commit -m "feat: add pve bootstrap script, first steps" -m "repos, users, pools and lxc-template steps, a dry-run mode, and stub
binaries with tests that prove a second run changes nothing."
```

---

### Task 2: Template steps and the cross-step tests

**Files:**
- Modify: `scripts/pve-bootstrap.sh` (replace the `# (Task 2 adds ...)` comment with the two functions), `scripts/tests/pve-bootstrap.test.sh` (add cases)

**Interfaces:**
- Consumes (Task 1): `run`, `note_*`, `die`, `vm_exists`, `vm_is_template`, `CACHE_DIR`, `ISO_DIR`, `STORAGE`, `UBUNTU_*`, `TALOS_*`, `TFVARS`, harness helpers listed in Task 1.
- Produces: `step_ubuntu_template`, `step_talos_template`.

- [ ] **Step 1: Add failing tests**

```bash
test_ubuntu_template_first_run() { new_env; run_script ubuntu-template; assert_rc 0
  assert_calls_contain 'apt-get install -y libguestfs-tools'
  assert_calls_contain 'virt-customize -a .*noble-server-cloudimg-amd64.img --install qemu-guest-agent'
  assert_calls_contain 'qm create 5000 --memory 2048 --cores 2 --name ubuntu-cid-tp'
  assert_calls_contain 'qm importdisk 5000 .* local-lvm'
  assert_calls_contain 'qm set 5000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-5000-disk-0'
  assert_calls_contain 'qm set 5000 --ide2 local-lvm:cloudinit'
  assert_calls_contain 'qm template 5000'
  [ ! -e "$CACHE_DIR/noble-server-cloudimg-amd64.img" ] || fail "image not cleaned up"; }
test_talos_template_first_run() { new_env; run_script talos-template; assert_rc 0
  assert_calls_contain 'wget .*factory.talos.dev/image/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515/v1.14.2/nocloud-amd64.raw.xz'
  assert_calls_contain 'xz -d'
  assert_calls_contain 'qm create 5001 --name talos-tp --memory 2048 --cores 2 --cpu x86-64-v2-AES --machine q35 --ostype l26 --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 --serial0 socket --agent enabled=1'
  assert_calls_contain 'qm set 5001 --scsi0 local-lvm:vm-5001-disk-0,discard=on,iothread=1,ssd=1 --boot order=scsi0 --ide2 local-lvm:cloudinit'
  assert_calls_contain 'qm template 5001'
  assert_out_contains 'no checksum'; }
test_templates_second_run() { new_env; run_script ubuntu-template talos-template; reset_calls
  run_script ubuntu-template talos-template; assert_rc 0; assert_calls_lack 'qm create|importdisk|qm template|wget|apt-get|virt-customize'; }
test_vmid_not_template() { new_env; mkdir -p "$S/vms"; echo "name: something" > "$S/vms/5000"
  run_script ubuntu-template; assert_rc_nonzero; assert_calls_lack 'qm create'; assert_out_contains 'not a template'
  echo "name: other" > "$S/vms/5001"; reset_calls
  run_script talos-template; assert_rc_nonzero; assert_calls_lack 'qm create'; }
test_bad_checksum() { new_env; STUB_BAD_SUM=1 run_script ubuntu-template; assert_rc_nonzero
  assert_calls_lack 'virt-customize'; assert_calls_lack 'qm create'; assert_out_contains 'checksum'; }
test_idempotent_second_run() {
  new_env; run_script; assert_rc 0; reset_calls; run_script; assert_rc 0
  assert_calls_lack 'pveum user add|pveum role add|user token add|pool add|pveum aclmod|pveam download|qm create|qm importdisk|qm template|useradd|chpasswd|wget|apt-get|^apt update'
  assert_out_contains 'skipped:'; }
test_dry_run_templates() { new_env; run_script --dry-run ubuntu-template talos-template; assert_rc 0
  assert_calls_lack 'qm create|qm template|virt-customize|apt-get install|wget'; }
test_node_name_warning() { new_env; STUB_HOSTNAME=pve2 run_script repos; assert_rc 0; assert_out_contains "node is 'pve2'"; }
```

(The `-- run_script` with no args runs all steps; `ADMIN_USER=opuser` is set by `new_env`.)

- [ ] **Step 2: Run, expect the new cases to fail**

Run: `bash scripts/tests/pve-bootstrap.test.sh`
Expected: the new cases FAIL (unknown step or missing functions); Task 1's still pass.

- [ ] **Step 3: Implement the two steps**

Replace the comment with:

```bash
# Volume that qm importdisk left unused (normally STORAGE:vm-ID-disk-0).
unused_volume() { qm config "$1" | sed -n 's/^unused0: *\([^,]*\).*/\1/p'; }

step_ubuntu_template() {
  local id="$UBUNTU_TEMPLATE_VMID" img="$UBUNTU_RELEASE-server-cloudimg-amd64.img" base vol
  base="https://cloud-images.ubuntu.com/$UBUNTU_RELEASE/current"
  if vm_exists "$id"; then
    vm_is_template "$id" || die "vmid $id exists but is not a template; remove it or pick another UBUNTU_TEMPLATE_VMID"
    note_skipped "ubuntu template $id"; TFVARS+=("clone_template_ubuntu = \"ubuntu-cid-tp\""); return 0
  fi
  run apt-get install -y libguestfs-tools
  run mkdir -p "$CACHE_DIR"
  run wget -q -O "$CACHE_DIR/$img" "$base/$img"
  run wget -q -O "$CACHE_DIR/SHA256SUMS" "$base/SHA256SUMS"
  if [ "$DRY_RUN" = 1 ]; then echo "+ verify $img against SHA256SUMS"; else
    ( cd "$CACHE_DIR" && grep -F " *$img" SHA256SUMS | sha256sum -c - >/dev/null ) \
      || { rm -f "$CACHE_DIR/$img" "$CACHE_DIR/SHA256SUMS"; die "checksum mismatch for $img"; }
  fi
  run virt-customize -a "$CACHE_DIR/$img" --install qemu-guest-agent
  run qm create "$id" --memory 2048 --cores 2 --name ubuntu-cid-tp
  run qm importdisk "$id" "$CACHE_DIR/$img" "$STORAGE"
  vol=$([ "$DRY_RUN" = 1 ] && echo "$STORAGE:vm-$id-disk-0" || unused_volume "$id")
  [ -n "$vol" ] || die "no unused disk on vmid $id after importdisk"
  run qm set "$id" --scsihw virtio-scsi-pci --scsi0 "$vol"
  run qm set "$id" --ide2 "$STORAGE:cloudinit"
  run qm set "$id" --boot c --bootdisk scsi0
  run qm set "$id" --serial0 socket --vga serial0
  run qm template "$id"
  run rm -f "$CACHE_DIR/$img" "$CACHE_DIR/SHA256SUMS"
  note_created "ubuntu template $id (ubuntu-cid-tp)"
  TFVARS+=("clone_template_ubuntu = \"ubuntu-cid-tp\"")
}

step_talos_template() {
  local id="$TALOS_TEMPLATE_VMID" xzf="$ISO_DIR/talos-nocloud.raw.xz" raw vol
  raw="${xzf%.xz}"
  if vm_exists "$id"; then
    vm_is_template "$id" || die "vmid $id exists but is not a template; remove it or pick another TALOS_TEMPLATE_VMID"
    note_skipped "talos template $id"; return 0
  fi
  run mkdir -p "$ISO_DIR"
  run wget -q -O "$xzf" "https://factory.talos.dev/image/$TALOS_SCHEMATIC/$TALOS_VERSION/nocloud-amd64.raw.xz"
  echo "note: Image Factory publishes no checksum for this image (the schematic id is content-addressed); no checksum verified."
  run xz -d "$xzf"
  run qm create "$id" --name talos-tp --memory 2048 --cores 2 --cpu x86-64-v2-AES --machine q35 --ostype l26 --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 --serial0 socket --agent enabled=1
  run qm importdisk "$id" "$raw" "$STORAGE"
  vol=$([ "$DRY_RUN" = 1 ] && echo "$STORAGE:vm-$id-disk-0" || unused_volume "$id")
  [ -n "$vol" ] || die "no unused disk on vmid $id after importdisk"
  run qm set "$id" --scsi0 "$vol,discard=on,iothread=1,ssd=1" --boot order=scsi0 --ide2 "$STORAGE:cloudinit"
  run qm template "$id"
  run rm -f "$raw"
  note_created "talos template $id (talos-tp)"
}
```

Note `qm create ... --name talos-tp` stub parses `--name` anywhere in argv; `qm set --scsi0 VOL,opts` stub treats any `--scsi0` as the trigger.

- [ ] **Step 4: Run, expect all green**

Run: `bash scripts/tests/pve-bootstrap.test.sh; bash -n scripts/pve-bootstrap.sh`
Expected: every case `ok`, `0 failed`. Also `bash scripts/pve-bootstrap.sh --dry-run` run under the test environment's stubs is covered by `test_dry_run_*`.

- [ ] **Step 5: Commit**

```bash
git add scripts
git commit -m "feat: add ubuntu and talos template steps" -m "Checksum-verified Ubuntu image, Talos nocloud image, refusal to touch
a vmid that is not a template, and tests for idempotency and failures."
```

---

### Task 3: The pin check, shellcheck hook and CI job

**Files:**
- Create: `scripts/check-talos-pins.sh`
- Modify: `scripts/tests/pve-bootstrap.test.sh` (two cases for the pin check), `.pre-commit-config.yaml`, `.github/workflows/ci.yaml`

**Interfaces:**
- Consumes: `TALOS_VERSION`/`TALOS_SCHEMATIC` assignments in `scripts/pve-bootstrap.sh` (exact form `TALOS_VERSION="${TALOS_VERSION:-<value>}"`), defaults in `terraform/environments/prod/variables.tf` (`variable "talos_version"` and `variable "talos_schematic_id"` blocks with a `default = "<value>"` line).
- Produces: `scripts/check-talos-pins.sh [script] [variables.tf]` — exits 0 when equal, non-zero with a message naming the mismatch; defaults to the repo paths.

- [ ] **Step 1: Failing tests**

Add to the test file:

```bash
test_pins_match() { new_env; bash "$HERE/../check-talos-pins.sh" >"$T/out" 2>&1; RC=$?; OUT=$(cat "$T/out"); assert_rc 0; }
test_pins_drift() { new_env; sed 's/v1.14.2/v9.9.9/' "$HERE/../pve-bootstrap.sh" > "$T/script.sh"
  bash "$HERE/../check-talos-pins.sh" "$T/script.sh" >"$T/out" 2>&1; RC=$?; OUT=$(cat "$T/out")
  assert_rc_nonzero; assert_out_contains "talos_version"; }
```

Run `bash scripts/tests/pve-bootstrap.test.sh`; expect these two FAIL (script missing).

- [ ] **Step 2: Write `scripts/check-talos-pins.sh`**

```bash
#!/usr/bin/env bash
# Fail when the Talos pins in pve-bootstrap.sh differ from the defaults in the
# prod root's variables.tf. The script runs on a host with no Terraform, so it
# carries its own copy; this keeps the two from drifting.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
script=${1:-$root/scripts/pve-bootstrap.sh}
tf=${2:-$root/terraform/environments/prod/variables.tf}

sh_val() { sed -n "s/^$1=\"\${$1:-\(.*\)}\"\$/\1/p" "$script"; }
tf_val() { awk -v v="variable \"$1\"" '$0 ~ v {f=1} f && /default/ {gsub(/^[^"]*"|"[^"]*$/, ""); print; exit}' "$tf"; }

rc=0
check() { # check SCRIPT_VAR TF_VAR
  local a b; a=$(sh_val "$1"); b=$(tf_val "$2")
  if [ -z "$a" ] || [ -z "$b" ]; then echo "cannot read $1 (script) or $2 (variables.tf)" >&2; rc=1
  elif [ "$a" != "$b" ]; then echo "$2 differs: script has '$a', variables.tf has '$b'" >&2; rc=1; fi
}
check TALOS_VERSION talos_version
check TALOS_SCHEMATIC talos_schematic_id
[ "$rc" = 0 ] && echo "talos pins match"
exit "$rc"
```

`chmod +x`. Run the tests; expect all green. Also run it directly: `bash scripts/check-talos-pins.sh` prints `talos pins match`.

- [ ] **Step 3: shellcheck hook**

In `.pre-commit-config.yaml`, add a repo entry before the `local` block:

```yaml
  # Only the bootstrap tooling is linted: the older scripts/ files predate
  # this hook and are not clean.
  - repo: https://github.com/shellcheck-py/shellcheck-py
    rev: v0.11.0.1
    hooks:
      - id: shellcheck
        files: ^scripts/(pve-bootstrap\.sh|check-talos-pins\.sh|tests/.*)$
```

Run `pre-commit run shellcheck --all-files` (downloads the hook env; needs network). Expected: Passed. Fix every finding in the new files (add a targeted `# shellcheck disable=SCxxxx` with a reason only where the plan's code already has one; do not blanket-disable). Stubs have no `.sh` extension and a bash shebang; if shellcheck skips them it is fine, if it flags them fix the stub.

- [ ] **Step 4: CI job**

In `.github/workflows/ci.yaml`, after the `manifests` job (read the file's last lines first to match indentation and pin style), add:

```yaml
  scripts:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      # shellcheck is preinstalled on the runner image.
      - name: shellcheck
        run: shellcheck scripts/pve-bootstrap.sh scripts/check-talos-pins.sh scripts/tests/pve-bootstrap.test.sh
      - name: talos pins match the prod root
        run: scripts/check-talos-pins.sh
      - name: pve-bootstrap tests
        run: scripts/tests/pve-bootstrap.test.sh
```

Update the comment block at the top of the workflow if it lists the jobs. Run `actionlint .github/workflows/ci.yaml` if installed. Make the three scripts executable (`git update-index --chmod=+x` or `chmod +x` before `git add`).

- [ ] **Step 5: Verify all**

```bash
pre-commit run --all-files
bash scripts/tests/pve-bootstrap.test.sh
bash scripts/check-talos-pins.sh
```
Expected: all pass; `git status --porcelain` empty after committing.

- [ ] **Step 6: Commit**

```bash
git add scripts .pre-commit-config.yaml .github/workflows/ci.yaml
git commit -m "ops: lint, pin-check and test the bootstrap" -m "shellcheck hook, a check that the script's Talos pins match the prod
root, and a scripts CI job running the stub tests."
```

---

### Task 4: Documentation

**Files:**
- Modify: `docs/rebuild.md`, `CLAUDE.md`, `README.md`, `docs/decisions/README.md`, `docs/superpowers/specs/2026-10-01-pve-bootstrap-design.md`
- Create: `docs/decisions/0022-host-bootstrapped-by-script.md`

**Interfaces:**
- Consumes: the script's steps and behaviours from Tasks 1-3.

- [ ] **Step 1: `docs/rebuild.md`**

Read sections 1, 2, 2b and Rebuild order steps 2-3 with `grep -n`/`sed -n` first. Then:
- Section 1 and 2 intros: lead with a block telling the operator to run the script on `pve`:

````markdown
**Run `scripts/pve-bootstrap.sh`.** It does everything in sections 1 and 2
and 2b below, and is safe to re-run. On the new host, as root:

```bash
wget https://raw.githubusercontent.com/maxim-grin/homelab/main/scripts/pve-bootstrap.sh
less pve-bootstrap.sh              # read it before running it as root
bash pve-bootstrap.sh --dry-run    # print what it would do
bash pve-bootstrap.sh              # all steps; or name some:
bash pve-bootstrap.sh pools talos-template   # steps: repos users pools lxc-template ubuntu-template talos-template
```

It prompts for the admin user's password (never echoed or stored) and
prints the Terraform API token's secret **once**: copy it into
`pm_api_token_secret`. At the end it lists the values for tfvars. Running it
again on a configured host changes nothing and reports every step as
skipped. It never destroys a template: if vmid 5000 or 5001 exists and is not
a template it stops and tells you what to do.
````
- Delete the command blocks the script now owns: apt sources, admin user, terraform user/role, pools/ACL, the `qm create...` template builds (Ubuntu and Talos), `pveam` download, `virt-customize`. KEEP all explanations and gotchas: why the enterprise repo is disabled, why the role needs per-pool ACLs, the cloud-init-bus note and the guest-agent history (these describe why, and the `qm destroy` rebuild line stays as the manual way to rebuild a template), `scsihw`, host assumptions (section 3). Where a deleted block was the only place a manual fallback existed (rebuilding an existing template), keep that one command.
- Section 2b becomes prose: what the `talos-template` step does, and the one manual command to rebuild `talos-tp` when `TALOS_VERSION`/schematic change (destroy template, re-run the step; the version lives in the script and in `terraform/environments/prod/variables.tf`, and CI fails if they differ).
- Rebuild order steps 2 and 3: say "run `scripts/pve-bootstrap.sh`" instead of listing the pieces; keep the pointers about the Debian LXC template string for `shared.tfvars`.
- Section 1 token paragraph: say the script creates the token with `--privsep 0` and why.
- Keep the file's existing style (headings, `bash` fences).

- [ ] **Step 2: `CLAUDE.md`, `README.md`**

CLAUDE.md: the paragraph near the top that says the host "is set up by hand and is not in Terraform" becomes "is set up by `scripts/pve-bootstrap.sh`, not by Terraform"; the Load-bearing bullet "`ubuntu-cid-tp` must exist before any `terraform apply`... nothing in this repository creates it" becomes: the script creates it (`pve-bootstrap.sh ubuntu-template`), run it first. README layout block: the `scripts/` entry also lists `pve-bootstrap.sh` (bootstrap a fresh Proxmox host) and `check-talos-pins.sh`; add the `scripts` job to the CI table with a one-line description. Edit minimally: another branch edits these files.

- [ ] **Step 3: ADR 0022 and the spec**

Create `docs/decisions/0022-host-bootstrapped-by-script.md` in the shape of ADR 0021 (read it first):

```markdown
# 0022. The Proxmox host is bootstrapped by a script

**Status:** Accepted (2026-10-01)

## Context

Everything under Terraform's feet — apt repos, users, the API token, resource
pools with their ACLs, and three VM/LXC templates — was built by hand from
`docs/rebuild.md`. A rebuild onto a new SSD means typing about forty commands
on a machine with no tooling, and the template build was duplicated in prose
and in code blocks.

## Decision

`scripts/pve-bootstrap.sh`, one standalone bash file run as root on `pve`,
does all of it in named, idempotent steps. It needs no repository checkout,
no Ansible and no Terraform, because on a bare host none of them exist yet.
Every mutating command goes through one wrapper, so `--dry-run` prints
instead of executing. Secrets are never written or logged; the API token
secret prints once. It never destroys a template. Its Talos version and
schematic are constants, and CI fails if they differ from the prod root's
defaults. shellcheck and stub-based tests (fake `qm`, `pveum`, `pveam`) run
in CI.

Rejected: an Ansible role (needs SSH and an inventory entry first), the
`bpg/proxmox` provider (a second provider on the same host, and it cannot
build templates), and reading the Talos pins from `variables.tf` at run time
(ties the script to a checkout and a grep over HCL).

## Consequences

A rebuild is `wget`, read, run. The stubs prove idempotency, not that the
real `pveum`/`pveam` output matches what the script expects; the first run
on a real host is the final test. `rebuild.md` keeps the reasons and drops the
duplicated commands.

## Related

`docs/superpowers/specs/2026-10-01-pve-bootstrap-design.md`; the Talos
prod record [0021](0021-talos-prod-via-terraform-provider.md).
```

Add its row to `docs/decisions/README.md` after the last row. In the spec: change the `users` bullet that says `terraform@pve` "is created with a random password that is never shown" to say it is created with no password (only its token is used), and in the Secrets paragraph keep "never echoes a password it generated" out (nothing is generated). Keep the spec otherwise unchanged.

- [ ] **Step 4: Verify**

```bash
grep -rIn "the Mac\|the laptop\|original author\|talos/_out" --exclude-dir=.git --exclude-dir=.superpowers . | grep -v "docs/superpowers/\(specs\|plans\)/"
pre-commit run --all-files
bash scripts/tests/pve-bootstrap.test.sh && bash scripts/check-talos-pins.sh
grep -n "terraform@pve --password\|adduser user1\|qm create 5000\|qm create 5001" docs/rebuild.md   # expect no command blocks left
```
Expected: the first grep and the last grep print nothing; hooks and tests pass. Check every `rebuild.md` claim about the script against the script (step names, vmids, prompts, `--dry-run`).

- [ ] **Step 5: Commit**

```bash
git add docs CLAUDE.md README.md
git commit -m "docs: point rebuild at the bootstrap script" -m "rebuild.md leads with the script and keeps the reasons; CLAUDE.md and
README mention it; ADR 0022 records the decision."
```

---

### Task 5: Final verification and PR description

**Files:** none modified, except fixes found here.

- [ ] **Step 1: Full local checks**

```bash
pre-commit run --all-files
bash scripts/tests/pve-bootstrap.test.sh
bash scripts/check-talos-pins.sh
for env in dev shared prod; do terraform -chdir=terraform/environments/$env init -backend=false -input=false >/dev/null && terraform -chdir=terraform/environments/$env validate; done
git status --porcelain
```
Expected: all pass, status empty (restore any lock file `init` touched with `git checkout -- <file>` and say so).

- [ ] **Step 2: Read the script once, adversarially**

`bash -n scripts/pve-bootstrap.sh`; `grep -n "set -x\|echo.*pw\|echo.*password" scripts/pve-bootstrap.sh` must show no password echo; confirm no `curl | bash` and no secret in the tests' committed files.

- [ ] **Step 3: PR description**

Write `/tmp/claude-1000/-home-ubuntu/bc3f83c2-866a-4656-bb7e-e3d055659db4/scratchpad/pr2-body.md`: keep the existing bullets (read with `gh pr view 73 --json body -q .body`), replace the "opens with the design only" sentence with one saying the branch now has spec, plan and implementation, and add "Operator steps": on `pve` run `wget` the script, `--dry-run` first, then a real run; on the already-configured live host expect every step `skipped`; and a "Checked first on the real host" list: `pvesh get /pools/<n>` and `/access/...` paths exist as assumed; `pveum acl list --noborder 1` output matches `has_acl` (if every run re-issues `aclmod` it is harmless); the token's secret prints once; the Ubuntu template build still produces `ubuntu-cid-tp`. Run `gh pr edit 73 --body-file <file>`. No footer, no session link. Do NOT run `gh pr ready`; the controller decides.
