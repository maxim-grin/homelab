# Proxmox Host Bootstrap Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One idempotent bash script takes a fresh Proxmox VE 9 host to the state `terraform apply` assumes, with stub tests in CI.

**Architecture:** `scripts/pve-bootstrap.sh` is standalone (no repo checkout needed on `pve`). Every mutating command goes through one `run` wrapper (`--dry-run` prints instead of executing). Each step checks state, acts, verifies. Tests run the real script against fake `qm`/`pveum`/`pveam`/... binaries on `PATH`, backed by a state directory.

**Tech Stack:** bash 5, shellcheck (via the `shellcheck-py` pre-commit hook), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-01-pve-bootstrap-design.md` (read it first; this plan implements it). The plan gives decisions, exact values and verification commands; the implementer writes the code.

## Global Constraints

- Work only in worktree `/home/ubuntu/homelab/.worktrees/pve-bootstrap`, branch `pve-bootstrap`. Never switch branches in `/home/ubuntu/homelab`, never bare `git stash`, never push (the controller pushes).
- No Proxmox access here. Only stub tests, `bash -n`, `--dry-run` against stubs, and CI-equivalent commands can run.
- Script: bash, `set -euo pipefail`, `set +x` forced. No file ever contains a secret; no password on a command line, in the environment, in a log, or echoed.
- Exact values:
  - `TALOS_VERSION` default `v1.14.2`
  - `TALOS_SCHEMATIC` default `ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515`
  - `UBUNTU_RELEASE` default `noble`
  - template vmids 5000 (`ubuntu-cid-tp`) and 5001 (`talos-tp`)
  - pools `VM Ubuntu-K8s LXC Talos-K8s`
  - role `TerraformProv`; user `terraform@pve`; token id `terraform` created with `--privsep 0`
  - storage `local-lvm`; node `pve`
  - role privileges, verbatim: `VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Monitor VM.Audit VM.PowerMgmt Datastore.AllocateSpace Datastore.Audit`
- Settings overridable from the environment: `TALOS_VERSION`, `TALOS_SCHEMATIC`, `UBUNTU_RELEASE`, `UBUNTU_TEMPLATE_VMID`, `TALOS_TEMPLATE_VMID`, `POOLS`, `STORAGE`, `ADMIN_USER`, and for testability `APT_SOURCES_DIR` (default `/etc/apt/sources.list.d`), `CACHE_DIR` (default `/var/lib/vz/template/cache`), `ISO_DIR` (default `/var/lib/vz/template/iso`).
- Never destroy or overwrite an existing VM or template: refuse and print the manual line.
- Commits: Conventional Commits, subject at most 50 characters, imperative, lowercase, types `feat fix refactor docs chore ops` only (no `ci`), body wrapped at 72, **no `Co-Authored-By`, no generated-with footer**, never `--no-verify`.
- Docs prose: "the operator's workstation", never "the Mac" or "the laptop"; no mention of the original author or the old `talos/_out` leak.
- Read narrowly: `grep -n` / `sed -n`, not `cat` of whole files.
- ADR number 0022 (0020 and 0021 are on other branches); renumber at merge if needed.

## Review Focus

1. **Second run changes nothing:** a full run on empty state, then a second run on the resulting state, issues no creating command (Task 2, case `idempotent_second_run`).
2. **Existing token:** never recreated, no secret printed, message says how to rotate (Task 1, case `token_exists`).
3. **A VM at 5000/5001 that is not a template:** the step stops non-zero and never runs `qm create` (Task 2, case `vmid_not_template`).
4. **Corrupt image:** a checksum mismatch aborts before `virt-customize` and deletes the download (Task 2, case `bad_checksum`).
5. **Secret leakage:** the typed admin password appears in no stub call log, no stdout or stderr (Task 1, case `no_password_leak`).

---

## File Structure

| Path | Action | Responsibility |
| --- | --- | --- |
| `scripts/pve-bootstrap.sh` | create | the script (Tasks 1-2) |
| `scripts/tests/pve-bootstrap.test.sh` | create | test runner and cases (Tasks 1-3) |
| `scripts/tests/stubs/` | create | fake binaries, one executable file each (Task 1) |
| `scripts/check-talos-pins.sh` | create | pin drift check (Task 3) |
| `.pre-commit-config.yaml` | modify | shellcheck hook (Task 3) |
| `.github/workflows/ci.yaml` | modify | `scripts` job (Task 3) |
| `docs/rebuild.md`, `CLAUDE.md`, `README.md`, `docs/decisions/0022-host-bootstrapped-by-script.md`, `docs/decisions/README.md`, the spec | modify/create | docs (Task 4) |

---

### Task 1: Skeleton, stubs, and the steps `repos`, `users`, `pools`, `lxc-template` — tests first

**Files:**
- Create: `scripts/pve-bootstrap.sh`, `scripts/tests/pve-bootstrap.test.sh`, `scripts/tests/stubs/*`

**Interfaces:**
- Produces for Task 2, in the script: helpers `run`, `die`, `note_created`, `note_changed`, `note_skipped`, `vm_exists ID`, `vm_is_template ID`; the variables above; step functions named `step_<name with - as _>` (`step_repos`, `step_users`, `step_pools`, `step_lxc_template`; Task 2 adds `step_ubuntu_template`, `step_talos_template`), dispatched from `main` by step name.
- Produces for Tasks 2-3, in the test file: `new_env` (fresh temp dir, state dir `$S`, `PATH` with the stubs first, `APT_SOURCES_DIR`/`CACHE_DIR`/`ISO_DIR` under the temp dir, `ADMIN_USER=opuser`, a `pve-enterprise.sources` containing `Types: deb`, unsets `STUB_*`), `run_script ARGS...` (pipes `secretpw` twice to stdin, captures `OUT` and `RC`), `reset_calls`, assertions `assert_rc N`, `assert_rc_nonzero`, `assert_calls_contain REGEX`, `assert_calls_lack REGEX`, `assert_out_contains TEXT`, `assert_out_lacks TEXT`, `fail MSG`; cases are functions named `test_*`, all run by the runner, which prints one `ok`/`FAIL` line per case and exits non-zero if any failed.

**Script decisions (the implementer writes the code):**

- Structure: settings block, helpers, preflight, one function per step, `summary`, `main`. `main` parses `--dry-run` and `-h/--help`, treats the rest as step names (default all, in the order `repos users pools lxc-template ubuntu-template talos-template`), rejects an unknown name with `unknown step '<x>'` and the list of valid ones, runs `preflight`, then each step under a `== <step> ==` heading, then `summary`.
- `preflight`: `id -u` must be 0 (`must run as root`); `pveversion` must exist (`this is not a Proxmox host`); if `hostname -s` is not `pve`, print `warning: node is '<name>', every tfvars file assumes 'pve'` to stderr and continue.
- `run`: with `--dry-run` print `+ <command>` instead of executing. Read-only checks (`pvesh get`, `qm config`, `pveum acl list`, `pveam list`) always run for real.
- Existence checks use `pvesh get <path>` and its exit status: `/access/users/<id>`, `/access/roles/<name>`, `/pools/<name>`, `/access/users/<user>/token/<token>`. VM checks use `qm config <id>` (exists) and its `template: 1` line (template).
- ACLs: `has_acl PATH USER ROLE` is true when one line of `pveum acl list --noborder 1` contains all three as whitespace-separated fields, in any column order. `ensure_acl PATH USER ROLE` runs `pveum aclmod PATH -user USER -role ROLE` and notes it created, or notes it skipped.
- `repos`: if `$APT_SOURCES_DIR/pve-enterprise.sources` exists and lacks `Enabled: false`, delete any `Enabled:` line and append `Enabled: false`. If `pve-no-subscription.sources` is missing, write it with exactly: `Types: deb`, `URIs: http://download.proxmox.com/debian/pve`, `Suites: trixie`, `Components: pve-no-subscription`, `Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg`. Run `apt update` only if either changed. In dry-run print `+ ...` lines and write nothing.
- `users`:
  - Admin user: name from `ADMIN_USER`, else a prompt if stdin is a tty, else skip with a note. If `id <user>` fails: read the password twice with `read -rs` (mismatch or empty is an error), install `sudo` if `command -v sudo` fails, `useradd -m -s /bin/bash -G sudo <user>`, set the password by piping `<user>:<password>` into `chpasswd`, then unset the variable. Then create `<user>@pam` with `pveum user add` (comment `<user> admin`) unless `pvesh get` finds it, and `ensure_acl / <user>@pam Administrator`.
  - `terraform@pve`: `pveum user add terraform@pve -comment Terraform` unless it exists. **No password** (only the token is used).
  - Role: if it exists run `pveum role modify TerraformProv -privs "<privileges>"` (always, so privileges match), else `pveum role add TerraformProv -privs "<privileges>"`. Then `ensure_acl / terraform@pve TerraformProv`.
  - Token: if it exists, print to stderr `token terraform@pve!terraform already exists; Proxmox cannot show its secret again.` and `to rotate: pveum user token remove terraform@pve terraform, then re-run this step.`, note skipped, create nothing. Otherwise print `Creating API token. The secret below is shown once; copy it into pm_api_token_secret.` then run `pveum user token add terraform@pve terraform --privsep 0` and let its output reach the terminal. Always add `pm_api_token_id = "terraform@pve!terraform"` to the tfvars values.
- `pools`: for each pool in `POOLS`: `pveum pool add <p>` unless `pvesh get /pools/<p>` succeeds, then `ensure_acl /pool/<p> terraform@pve TerraformProv`.
- `lxc-template`: `pveam update`; pick the newest name matching `debian-13-standard_*` from `pveam available --section system` using version sort; die if none; `pveam download local <name>` unless `pveam list local` already lists it; add `debian_lxc_template = "local:vztmpl/<name>"` to the tfvars values.
- `summary`: lines `created: ...`, `changed: ...`, `skipped: ...`, then a `== values for tfvars ==` section if any. Must work with empty arrays under `set -u`.

**Stub contract** (each stub is an executable bash file in `scripts/tests/stubs/`, first appends its full command line to `$S/calls.log`, writes only under `$S`):
- `pvesh get PATH`: exit 0 iff the object exists: `$S/users/<id>`, `$S/roles/<name>`, `$S/pools/<name>`, `$S/tokens/<user>!<token>`; otherwise exit 1.
- `pveum`: `user add ID` touches `$S/users/ID`; `role add|modify NAME` writes `$S/roles/NAME`; `pool add NAME` touches `$S/pools/NAME`; `aclmod PATH -user U -role R` appends the line `U PATH 1 R user` to `$S/acl`; `acl list ...` prints `$S/acl`; `user token add U T ...` creates `$S/tokens/U!T` and prints a boxed table that includes a line whose value column is `11111111-2222-3333-4444-555555555555`.
- `pveam`: `update` logs; `available --section system` prints three lines `system          debian-12-standard_12.7-1_amd64.tar.zst`, `... debian-13-standard_13.0-1_amd64.tar.zst`, `... debian-13-standard_13.1-2_amd64.tar.zst`; `list local` prints the names under `$S/pveam/`; `download local NAME` touches `$S/pveam/NAME`.
- `qm`: `config ID` exits 2 if `$S/vms/ID` is absent, else prints it; `create ID ... --name N` creates it with `name: N`; `importdisk ID FILE STORAGE` appends `unused0: STORAGE:vm-ID-disk-0`; `set ID ...` removes `unused0:` and appends a `scsi0:` line when `--scsi0` is present; `template ID` appends `template: 1`.
- `pveversion` prints `pve-manager/9.0.3/abc123 (running kernel: 6.14.8-2-pve)`; `hostname` prints `${STUB_HOSTNAME:-pve}` and accepts `-s`; `id -u` prints `${STUB_UID:-0}`; `id NAME` exits 0 iff `$S/linux_users/NAME` exists; `useradd ... NAME` creates that file; `usermod`, `apt`, `apt-get`, `virt-customize`, `sudo` only log (or are empty); `getent group sudo` exits 0; `chpasswd` logs only the string `chpasswd` to calls.log and appends only the username part of each stdin line to `$S/chpasswd.log`, never the password.
- `wget`: writes the `-O` target (or the URL basename) with the content `FAKEIMG`; for a URL ending `SHA256SUMS` it writes the line `<sha256 of that exact content> *noble-server-cloudimg-amd64.img` (a wrong hash when `STUB_BAD_SUM=1`). `xz -d FILE.xz` creates `FILE` with the same content and removes `FILE.xz`.

**Test cases for this task** (each a `test_*` function in the test file):
- `unknown_step`: `nosuchstep` exits non-zero, output contains `unknown step`.
- `not_root`: `STUB_UID=1000` with `repos` exits non-zero, output contains `must run as root`.
- `dry_run_changes_nothing`: `--dry-run repos users pools lxc-template` exits 0; calls.log lacks `pveum (user add|role add|pool add|aclmod)`, `pveam download`, `useradd`, `chpasswd`, `apt-get`, `^apt update`; output contains `+ `; no `.sources` file was written.
- `repos_first_run`: exits 0; the enterprise file has `Enabled: false`; the no-subscription file exists and contains `pve-no-subscription`; calls.log has `apt update`.
- `repos_second_run`: after a first run, a second exits 0 and calls.log lacks `apt update`.
- `users_first_run`: calls.log contains `pveum user add terraform@pve`, `pveum role add TerraformProv`, `pveum aclmod / -user terraform@pve -role TerraformProv`, `pveum user token add terraform@pve terraform --privsep 0`, `useradd`, `pveum user add opuser@pam`, `pveum aclmod / -user opuser@pam -role Administrator`; output contains the fake token value; calls.log has no `--password`.
- `no_password_leak`: after `users`, `secretpw` appears in neither calls.log nor the output nor `chpasswd.log`.
- `token_exists`: with the user and token pre-seeded, `users` exits 0, calls.log lacks `user token add`, output lacks the fake token value and contains `already exists`.
- `pools_idempotent`: first run issues `pveum pool add` and the `aclmod /pool/<p> -user terraform@pve -role TerraformProv` for all four pools; after `reset_calls`, a second run issues neither.
- `lxc_template`: first run calls `pveam download local debian-13-standard_13.1-2_amd64.tar.zst` (the newest, not 13.0-1) and prints `local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst`; a second run does not download.

- [ ] **Step 1: Write the stubs and the test harness with the cases above**

Create the stub files per the contract and `scripts/tests/pve-bootstrap.test.sh` per the interfaces and cases. Make everything under `scripts/tests/stubs/` executable (`chmod +x`).

- [ ] **Step 2: Run, expect failure**

Run: `bash scripts/tests/pve-bootstrap.test.sh`
Expected: every case FAILs because `scripts/pve-bootstrap.sh` does not exist yet. Record the summary line.

- [ ] **Step 3: Write `scripts/pve-bootstrap.sh` per the decisions above**

Header comment: one paragraph saying what it does, the usage line `bash pve-bootstrap.sh [--dry-run] [step ...]`, the step list, and that secrets are never written or logged.

- [ ] **Step 4: Run, expect green**

Run: `bash scripts/tests/pve-bootstrap.test.sh && bash -n scripts/pve-bootstrap.sh`
Expected: all cases `ok`, summary `0 failed`. If a case fails because a stub is wrong, fix the stub; if because the script is wrong, fix the script. Never weaken an assertion; report a real mismatch.

- [ ] **Step 5: Commit**

```bash
git add scripts
git commit -m "feat: add pve bootstrap script, first steps" -m "repos, users, pools and lxc-template steps, a dry-run mode, and stub
binaries with tests that prove a second run changes nothing."
```

---

### Task 2: Template steps and the cross-step tests

**Files:**
- Modify: `scripts/pve-bootstrap.sh`, `scripts/tests/pve-bootstrap.test.sh`

**Interfaces:**
- Consumes: Task 1's helpers, variables, stubs and harness.
- Produces: `step_ubuntu_template`, `step_talos_template`; a helper that returns the volume `qm importdisk` left as `unused0` (parse `qm config`, take the value up to the first comma); in dry-run the volume is assumed to be `<STORAGE>:vm-<id>-disk-0`.

**Script decisions:**

- `ubuntu-template` (vmid `UBUNTU_TEMPLATE_VMID`):
  - If the vmid exists and is a template: note skipped, add `clone_template_ubuntu = "ubuntu-cid-tp"` to the tfvars values, return.
  - If it exists and is not a template: die with `vmid <id> exists but is not a template; remove it or pick another UBUNTU_TEMPLATE_VMID`.
  - Otherwise, in this order: `apt-get install -y libguestfs-tools`; create `CACHE_DIR`; download `https://cloud-images.ubuntu.com/<release>/current/<release>-server-cloudimg-amd64.img` and, from the same directory, `SHA256SUMS` into `CACHE_DIR`; verify with `sha256sum -c` on the line for that image (`grep -F " *<image>"`); on mismatch delete both files and die with a message containing `checksum mismatch`; `virt-customize -a <image> --install qemu-guest-agent`; `qm create <id> --memory 2048 --cores 2 --name ubuntu-cid-tp`; `qm importdisk <id> <image> <STORAGE>`; then, with the unused volume, `qm set <id> --scsihw virtio-scsi-pci --scsi0 <volume>`, `qm set <id> --ide2 <STORAGE>:cloudinit`, `qm set <id> --boot c --bootdisk scsi0`, `qm set <id> --serial0 socket --vga serial0`; `qm template <id>`; delete the image and `SHA256SUMS`. Note created; add the tfvars value.
- `talos-template` (vmid `TALOS_TEMPLATE_VMID`):
  - Exists-and-template: note skipped, return. Exists-and-not-template: die with the same message form (`TALOS_TEMPLATE_VMID`).
  - Otherwise: create `ISO_DIR`; download `https://factory.talos.dev/image/<TALOS_SCHEMATIC>/<TALOS_VERSION>/nocloud-amd64.raw.xz` to `ISO_DIR/talos-nocloud.raw.xz`; print `note: Image Factory publishes no checksum for this image (the schematic id is content-addressed); no checksum verified.`; `xz -d` it; `qm create <id> --name talos-tp --memory 2048 --cores 2 --cpu x86-64-v2-AES --machine q35 --ostype l26 --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 --serial0 socket --agent enabled=1`; `qm importdisk <id> <raw> <STORAGE>`; then, with the unused volume, `qm set <id> --scsi0 <volume>,discard=on,iothread=1,ssd=1 --boot order=scsi0 --ide2 <STORAGE>:cloudinit`; `qm template <id>`; delete the raw file. Note created.
- If `importdisk` left no `unused0`, die with `no unused disk on vmid <id> after importdisk`.

**Test cases to add:**
- `ubuntu_template_first_run`: calls contain `apt-get install -y libguestfs-tools`, `virt-customize -a ... noble-server-cloudimg-amd64.img --install qemu-guest-agent`, `qm create 5000 --memory 2048 --cores 2 --name ubuntu-cid-tp`, `qm importdisk 5000`, `qm set 5000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-5000-disk-0`, `qm set 5000 --ide2 local-lvm:cloudinit`, `qm template 5000`; the image is gone from `CACHE_DIR` afterwards.
- `talos_template_first_run`: the wget URL contains the exact schematic and `v1.14.2`; calls contain `xz -d`, the full `qm create 5001 ...` line from the decisions, the `qm set 5001 --scsi0 local-lvm:vm-5001-disk-0,discard=on,iothread=1,ssd=1 --boot order=scsi0 --ide2 local-lvm:cloudinit` line, `qm template 5001`; output contains `no checksum`.
- `templates_second_run`: after a first run of both, a second exits 0 and calls lack `qm create`, `importdisk`, `qm template`, `wget`, `apt-get`, `virt-customize`.
- `vmid_not_template`: with `$S/vms/5000` present and no `template: 1`, `ubuntu-template` exits non-zero, calls lack `qm create`, output contains `not a template`; the same for 5001 and `talos-template`.
- `bad_checksum`: `STUB_BAD_SUM=1` makes `ubuntu-template` exit non-zero; calls lack `virt-customize` and `qm create`; output contains `checksum`; the downloaded image is deleted.
- `idempotent_second_run`: `run_script` with no arguments (all steps) exits 0; after `reset_calls`, a second all-steps run exits 0 and calls lack `pveum user add`, `pveum role add`, `user token add`, `pool add`, `pveum aclmod`, `pveam download`, `qm create`, `qm importdisk`, `qm template`, `useradd`, `chpasswd`, `wget`, `apt-get`, `^apt update`; output contains `skipped:`. (`pveum role modify` is allowed.)
- `dry_run_templates`: `--dry-run ubuntu-template talos-template` exits 0 and calls lack `qm create`, `qm template`, `virt-customize`, `apt-get install`, `wget`.
- `node_name_warning`: `STUB_HOSTNAME=pve2` with `repos` exits 0 and the output contains `node is 'pve2'`.

- [ ] **Step 1: Add the cases, run, expect the new ones to FAIL; Task 1's still pass**

Run: `bash scripts/tests/pve-bootstrap.test.sh`

- [ ] **Step 2: Implement the two steps and the volume helper per the decisions**

- [ ] **Step 3: Run, expect all green**

Run: `bash scripts/tests/pve-bootstrap.test.sh && bash -n scripts/pve-bootstrap.sh`
Expected: every case `ok`, `0 failed`.

- [ ] **Step 4: Commit**

```bash
git add scripts
git commit -m "feat: add ubuntu and talos template steps" -m "Checksum-verified Ubuntu image, Talos nocloud image, refusal to touch
a vmid that is not a template, and tests for idempotency and failures."
```

---

### Task 3: Pin check, shellcheck hook, CI job

**Files:**
- Create: `scripts/check-talos-pins.sh`
- Modify: `scripts/tests/pve-bootstrap.test.sh`, `.pre-commit-config.yaml`, `.github/workflows/ci.yaml`

**Interfaces:**
- Consumes: in `scripts/pve-bootstrap.sh`, the assignments `TALOS_VERSION="${TALOS_VERSION:-<value>}"` and `TALOS_SCHEMATIC="${TALOS_SCHEMATIC:-<value>}"` (keep exactly that form); in `terraform/environments/prod/variables.tf`, the `default = "<value>"` line inside `variable "talos_version"` and `variable "talos_schematic_id"`.
- Produces: `scripts/check-talos-pins.sh [script] [variables.tf]`: exit 0 and print `talos pins match` when both pairs are equal; otherwise exit non-zero and print a line naming the variable that differs (`talos_version` or `talos_schematic_id`) with both values; exit non-zero with a message when a value cannot be read. Defaults to the repo's two paths, found relative to the script's own location.

**Decisions:**
- Test cases to add: `pins_match` (default paths, exit 0) and `pins_drift` (a temp copy of the script with `v1.14.2` replaced by `v9.9.9`, exit non-zero, output names `talos_version`). Write them first and see them FAIL.
- Pre-commit: add the repo `https://github.com/shellcheck-py/shellcheck-py`, `rev: v0.11.0.1`, hook id `shellcheck`, `files` limited to the new tooling: `^scripts/(pve-bootstrap\.sh|check-talos-pins\.sh|tests/.*)$`, with a comment that the older `scripts/` files predate the hook and are not clean. Place it before the `local` block.
- CI: a new job `scripts` after `manifests`, same style as its neighbours (`runs-on: ubuntu-24.04`, `timeout-minutes: 10`, the pinned `actions/checkout` line with `persist-credentials: false`; read the file first to copy the exact pin). Steps: `shellcheck` on `scripts/pve-bootstrap.sh scripts/check-talos-pins.sh scripts/tests/pve-bootstrap.test.sh` (preinstalled on the runner image); `scripts/check-talos-pins.sh`; `scripts/tests/pve-bootstrap.test.sh`. Update the file's top comment if it lists the jobs.
- The three scripts must be executable in git.

- [ ] **Step 1: Add the two cases; run; expect them to FAIL**

Run: `bash scripts/tests/pve-bootstrap.test.sh`

- [ ] **Step 2: Write `scripts/check-talos-pins.sh`; run the tests; expect green; run it directly**

Run: `bash scripts/tests/pve-bootstrap.test.sh; bash scripts/check-talos-pins.sh`
Expected: all `ok`; the second prints `talos pins match`.

- [ ] **Step 3: Add the pre-commit hook and fix every finding in the new files**

Run: `pre-commit run shellcheck --all-files` (needs network for the hook environment).
Expected: Passed. Fix findings in the code; add a targeted `# shellcheck disable=SCxxxx` with a one-line reason only where a rule is genuinely wrong for that line. Stubs are linted too if they have a bash shebang: fix them.

- [ ] **Step 4: Add the CI job; validate it**

Run: `actionlint .github/workflows/ci.yaml` if installed, else say it is absent; `git diff .github/workflows/ci.yaml` to confirm only the new job and comment changed.

- [ ] **Step 5: Verify, commit**

```bash
pre-commit run --all-files
bash scripts/tests/pve-bootstrap.test.sh
bash scripts/check-talos-pins.sh
git add scripts .pre-commit-config.yaml .github/workflows/ci.yaml
git commit -m "ops: lint, pin-check and test the bootstrap" -m "shellcheck hook, a check that the script's Talos pins match the prod
root, and a scripts CI job running the stub tests."
```
Expected: all pass; `git status --porcelain` is empty after the commit.

---

### Task 4: Documentation

**Files:**
- Modify: `docs/rebuild.md`, `CLAUDE.md`, `README.md`, `docs/decisions/README.md`, `docs/superpowers/specs/2026-10-01-pve-bootstrap-design.md`
- Create: `docs/decisions/0022-host-bootstrapped-by-script.md`

**Interfaces:**
- Consumes: the script's real behaviour (read it, do not guess): step names, prompts, `--dry-run`, vmids, messages.

**Decisions:**
- `docs/rebuild.md`: read sections 1, 2, 2b and the rebuild-order steps 2-3 with `grep -n`/`sed -n` first.
  - Sections 1 and 2 open with "Run `scripts/pve-bootstrap.sh`": on the new host as root, `wget` the raw file from `https://raw.githubusercontent.com/maxim-grin/homelab/main/scripts/pve-bootstrap.sh`, read it, run it with `--dry-run` first, then for real; a step can be named (example `bash pve-bootstrap.sh pools talos-template`); valid steps `repos users pools lxc-template ubuntu-template talos-template`. Say: it prompts for the admin password (never echoed or stored), prints the API token secret **once** (copy it into `pm_api_token_secret`), ends by listing the tfvars values, is safe to re-run (a configured host reports every step skipped), and never destroys a template.
  - Delete the command blocks the script now owns: apt sources, admin user, terraform user/role, pools and ACLs, the template builds for Ubuntu and Talos, the `pveam` download, `virt-customize`.
  - Keep every explanation and gotcha: why the enterprise repo is disabled, why the role needs per-pool ACLs (it carries no `Pool.*` privileges), the cloud-init bus note, the guest-agent history, `scsihw`, section 3's host assumptions. Keep the one manual line for rebuilding an existing template (`qm destroy <vmid>`, then re-run the step).
  - Section 2b becomes prose: what the `talos-template` step does, and how to rebuild `talos-tp` when the version changes (destroy the template, change `TALOS_VERSION`/`TALOS_SCHEMATIC` in the script and the defaults in `terraform/environments/prod/variables.tf` together — CI fails if they differ — re-run the step).
  - Token paragraph: the script creates it with `--privsep 0`, because a privilege-separated token carries none of the user's permissions.
  - Rebuild-order steps 2 and 3 say "run `scripts/pve-bootstrap.sh`" instead of listing the pieces; keep the pointer about the Debian LXC template string for `shared.tfvars`.
- `CLAUDE.md`: the opening paragraph's "set up by hand and is not in Terraform" becomes set up by `scripts/pve-bootstrap.sh`, not Terraform; the "`ubuntu-cid-tp` must exist before any `terraform apply`" bullet says the script creates it. In "Verifying, with no test suite": the opening sentence "Nothing here has tests" becomes true only of the cluster (the bootstrap script has stub tests); add `scripts/tests/pve-bootstrap.test.sh` and `scripts/check-talos-pins.sh` to the command list; add `scripts` to the sentence listing the CI jobs (`pre-commit`, `commits`, `terraform`, `manifests`). Minimal edits; the Glance branch edits this file too.
- `README.md`: the `scripts/` layout entry lists `pve-bootstrap.sh` (bootstraps a fresh Proxmox host) and `check-talos-pins.sh`; add the `scripts` job to the CI table with a one-line description.
- ADR `0022-host-bootstrapped-by-script.md`, same shape as ADR 0021 (read it first): Status Accepted (2026-10-01). Context: host steps were forty-odd hand-typed commands, template build duplicated. Decision: one standalone bash script, named idempotent steps, one `run` wrapper for `--dry-run`, secrets never written or logged, token secret printed once, never destroys a template, Talos pins as constants checked against the prod root in CI, shellcheck and stub tests in CI. Rejected: an Ansible role (needs SSH and an inventory entry first), the `bpg/proxmox` provider (a second provider on one host, cannot build templates), reading the pins from `variables.tf` at run time. Consequences: stubs prove idempotency, not that real `pveum`/`pveam` output matches; the first real run is the final test. Related: the spec and ADR 0021. Add its row to `docs/decisions/README.md` after the last row.
- Spec correction: where it says `terraform@pve` is created "with a random password that is never shown", say it is created with no password (only its token is used); the Secrets paragraph's "never echoes a password it generated" becomes "never echoes a password".

- [ ] **Step 1: Make the doc changes above**

- [ ] **Step 2: Verify**

```bash
grep -rIn "the Mac\|the laptop\|original author\|talos/_out" --exclude-dir=.git --exclude-dir=.superpowers . | grep -v "docs/superpowers/\(specs\|plans\)/"
grep -n "adduser user1\|qm create 5000\|qm create 5001\|pveum user add terraform@pve --password" docs/rebuild.md
pre-commit run --all-files
bash scripts/tests/pve-bootstrap.test.sh && bash scripts/check-talos-pins.sh
```
Expected: both greps print nothing; hooks and tests pass. Check every claim `rebuild.md` makes about the script against the script itself (step names, vmids, prompts, flags).

- [ ] **Step 3: Commit**

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
Expected: all pass; status empty. Restore any tracked lock file `init` touched (`git checkout -- <file>`) and say so.

- [ ] **Step 2: Secrets check on the script and tests**

```bash
bash -n scripts/pve-bootstrap.sh
grep -n "set -x" scripts/pve-bootstrap.sh
grep -nE "(echo|printf).*(pw|pass)" scripts/pve-bootstrap.sh
```
Expected: `set -x` appears only as `set +x`; no line echoes a password variable; no `curl | bash` anywhere in `scripts/` or `docs/rebuild.md` (`grep -rn "| *bash" scripts docs/rebuild.md` prints nothing).

- [ ] **Step 3: PR description**

Write the body to `/tmp/claude-1000/-home-ubuntu/bc3f83c2-866a-4656-bb7e-e3d055659db4/scratchpad/pr2-body.md`: keep the existing bullets (`gh pr view 73 --json body -q .body`), replace the "opens with the design only" sentence with one saying the branch now holds spec, plan and implementation, and add:
- **Operator steps:** on `pve`, `wget` the script, read it, `--dry-run`, then run; on the already-configured live host expect every step `skipped` and no changes.
- **Checked first on the real host:** the `pvesh get` paths used for existence checks exist as assumed; `pveum acl list --noborder 1` output matches the ACL check (if every run re-issues `aclmod` it is harmless); the token secret prints once; the Ubuntu template build still yields `ubuntu-cid-tp`.
No footer, no session link. Run `gh pr edit 73 --body-file <file>`. Do NOT run `gh pr ready`.
