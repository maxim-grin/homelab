# Proxmox Host Bootstrap Script — Design

Replace the copy-pasted shell in `docs/rebuild.md` sections 1 and 2 with one
idempotent script, `scripts/pve-bootstrap.sh`, that takes a fresh Proxmox VE 9
install to the state `terraform apply` assumes. Follow-up to the Talos prod
design ([2026-10-01](2026-10-01-talos-prod-design.md)), which added a third
hand-built template and a fourth pool to the list.

## Problem

Everything under the Proxmox host is built by hand and is not in Terraform.
`docs/rebuild.md` carries it as paste-and-run blocks:

- apt repositories (enterprise off, no-subscription on)
- the admin user
- the `terraform@pve` user, the `TerraformProv` role and an API token
- four resource pools and the per-pool ACL each needs
- the Debian 13 LXC template for the LAN services
- the `ubuntu-cid-tp` template (vmid 5000)
- the `talos-tp` template (vmid 5001)

A rebuild onto a new SSD is the next real use of that list, and the roadmap
plans it as a drill. Doing it from a document means typing roughly forty
commands in order, on a machine with no tooling, and discovering the
omissions one failed `terraform apply` at a time. The commands are also
duplicated: the template build appears in prose, in a code block and, for the
guest agent, in a second block.

## Decisions

| Question | Decision |
| --- | --- |
| Scope | Everything in `rebuild.md` sections 1 and 2: repos, users, pools, all three templates |
| Form | One bash script, `scripts/pve-bootstrap.sh`, run as root on `pve` |
| Standalone | No repo checkout needed: `wget` the file, read it, run it |
| Steps | `repos`, `users`, `pools`, `lxc-template`, `ubuntu-template`, `talos-template`; default is all, in that order |
| Re-runs | Every step checks state first and does nothing if it is already right |
| Secrets | Never written to a file or logged; passwords come from prompts or are generated and discarded; the API token secret prints once |
| Talos pins | `TALOS_VERSION` and `TALOS_SCHEMATIC` are constants in the script; CI fails if they differ from `terraform/environments/prod/variables.tf` |
| Testing | `--dry-run`, shellcheck, and stub-based idempotency tests in a new CI job |
| Existing templates | Never destroyed; the script refuses and prints the `qm destroy` line |
| Docs | `rebuild.md` leads with the script and keeps the reasons and gotchas; the duplicated command blocks go |
| Branch | `pve-bootstrap`, cut from `talos-prod`; draft PR based on `talos-prod`, retargeted to `main` once #66 merges |

### Why one standalone script

On a bare host there is no Ansible inventory yet, no Terraform, and no
checkout of this repository. `rebuild.md` step 2 is the first thing that
happens after installing Proxmox. A bash file with no dependencies beyond what
Proxmox ships is the only form that works at that point. Ansible needs SSH
and an inventory entry first; Terraform's `bpg/proxmox` provider would add a
second provider managing the same host and still could not build templates.

### Why constants and a CI check for the Talos pins

The script runs on `pve`, where there is no Terraform to read
`variables.tf`. Parsing HCL with grep at run time would tie the script to a
full checkout and a fragile pattern. A shared config file read by both would
change the prod root for a host script. Constants in the script, with a CI
check that fails the PR when they drift, keep the script standalone and make
a mismatch impossible to merge. The Ubuntu template has no Terraform pin, so
its release (`noble`) is simply a constant without a check.

## Design

### Interface

```bash
wget https://raw.githubusercontent.com/maxim-grin/homelab/main/scripts/pve-bootstrap.sh
less pve-bootstrap.sh          # read it before running it as root
bash pve-bootstrap.sh [--dry-run] [step ...]
```

Before doing anything the script checks that it is root, that `pveversion`
exists, and warns if the node is not called `pve`, which every tfvars file
assumes. Settings are variables at the top, overridable from the
environment: `TALOS_VERSION`, `TALOS_SCHEMATIC`, `UBUNTU_RELEASE` (`noble`),
`UBUNTU_TEMPLATE_VMID` (5000), `TALOS_TEMPLATE_VMID` (5001), `ADMIN_USER`, and
the pool list (`VM Ubuntu-K8s LXC Talos-K8s`).

Every state-changing command goes through one `run` function. With
`--dry-run` it prints the command instead of executing it. The stub tests
run the real script against fake binaries on `PATH`.

### Steps

Each step is a function: check, act, verify. A second run issues no creating
command.

**`repos`.** Write `pve-no-subscription.sources` if missing; set
`Enabled: false` in `pve-enterprise.sources`; run `apt update` only if
either changed.

**`users`.**
- The admin user (`ADMIN_USER`, or prompted for): create the Linux user, add it
  to `sudo`, create `<user>@pam`, grant `Administrator` on `/`. The passwords
  are read with `read -s` and piped in, never passed on a command line.
- `terraform@pve`: created with a random password that is never shown, since
  only the token is used.
- `TerraformProv`: created with the privilege list from `rebuild.md`, or
  modified so its privileges match if it already exists. Granted on `/`.
- Token `terraform@pve!terraform`: created with `--privsep 0`, because a
  privilege-separated token carries none of the user's permissions. The
  secret prints once, to the terminal only. If the token already exists the
  script says so and how to rotate it (`pveum user token remove`, re-run),
  because Proxmox cannot show a secret twice.

**`pools`.** For each pool: `pveum pool add` if missing, then
`pveum aclmod /pool/<name> -user terraform@pve -role TerraformProv`. Without
the per-pool ACL, placement fails.

**`lxc-template`.** `pveam update`, pick the newest `debian-13-standard_*`,
download it unless present, and print the exact string for
`debian_lxc_template` in `shared.tfvars`.

**`ubuntu-template`.** Skip if vmid 5000 is already a template. Otherwise
install `libguestfs-tools`, download the cloud image, verify it against
Ubuntu's published `SHA256SUMS`, `virt-customize --install qemu-guest-agent`,
and run the `qm create`, `importdisk`, `set` and `template` sequence that
`rebuild.md` documents today. If vmid 5000 exists but is not a template, the
step stops and prints how to rebuild by hand; it never overwrites a VM.

**`talos-template`.** The same shape for vmid 5001 from the Image Factory
`nocloud` disk image (`$TALOS_VERSION`, `$TALOS_SCHEMATIC`). The factory
publishes no checksum for the image; the schematic ID is content-addressed,
and the script says so in its output rather than pretending to verify.

**Summary.** The script ends with what it created, changed and skipped, and
the values to copy into tfvars: the token id, `debian_lxc_template`, and the
template names.

### Secrets

No step writes a file containing a secret. `set +x` is forced. The only
secret the operator carries away is the token secret, printed once. The
script never echoes a password it generated.

### Layout

| Path | Purpose |
| --- | --- |
| `scripts/pve-bootstrap.sh` | the script |
| `scripts/tests/pve-bootstrap.test.sh` | stub-based tests |
| `scripts/tests/stubs/` | fake `qm`, `pveum`, `pveam`, `pvesm`, `apt-get`, `wget`, `virt-customize` |
| `scripts/check-talos-pins.sh` | fails if the script's Talos pins differ from `variables.tf` |

## Testing

No test can reach a real Proxmox host here, so there are three layers.

1. **shellcheck** joins `.pre-commit-config.yaml`.
2. **Stub tests.** The test script puts the fake binaries on `PATH`, backed
   by a state directory. Run 1 on an empty state asserts each creating
   command is issued; run 2 against the resulting state asserts none is. It
   also covers: an existing token is reported, not recreated; an existing
   non-template vmid stops the step; `--dry-run` issues nothing; an unknown
   step name exits non-zero; running without root exits non-zero.
3. **The pin check** compares `TALOS_VERSION` and `TALOS_SCHEMATIC` with the
   defaults in `terraform/environments/prod/variables.tf`.

Layers 2 and 3 run in a new CI job `scripts`. The real check is the
operator's run on `pve`, which the PR description lists, and it is a
drill: the script is idempotent, so running it on the live host should
report "skipped" for every step and change nothing.

## Documentation

- **`docs/rebuild.md`:** sections 1 and 2 lead with "run
  `scripts/pve-bootstrap.sh`". The reasons and gotchas stay (why pool ACLs
  exist, the cloud-init bus, the guest-agent history, why `scsihw` differs);
  the command blocks the script now owns go, so the two cannot drift. Rebuild
  order steps 2 and 3 point at the script. Section 2b (Talos) becomes a
  description of what the `talos-template` step does and how to rebuild the
  template by hand when the Talos version changes.
- **`CLAUDE.md`:** the opening paragraph and the "`ubuntu-cid-tp` must exist"
  bullet say the host is set up by `scripts/pve-bootstrap.sh`, not "by hand".
- **`README.md`:** the layout line for `scripts/` lists the script.
- **ADR:** "The host is bootstrapped by a script, not Terraform or Ansible",
  numbered at merge time because 0020 and 0021 are on other branches.

## Pull request shape

One draft PR based on `talos-prod`, opened when this spec is committed.
Commits, in order:

1. `docs:` this spec
2. `feat:` the script, with its stubs and tests
3. `ops:` the `scripts` CI job, the pin check and the shellcheck hook
4. `docs:` `rebuild.md`, CLAUDE.md, README and the ADR

The PR retargets to `main` after #66 merges. If #66 changes in review, this
branch merges `talos-prod` in.

## Out of scope

- Installing Proxmox itself.
- Anything after the host is ready: Terraform, Ansible, the clusters.
- Rebuilding or upgrading an existing template. The script refuses; that is
  a deliberate manual step.
- The Vault CA, secrets and tfvars files on the operator's workstation.
- A Proxmox-in-a-VM rehearsal harness.
