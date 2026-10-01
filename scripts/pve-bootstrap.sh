#!/usr/bin/env bash
# pve-bootstrap.sh - bring a fresh Proxmox VE 9 install to the state that
# `terraform apply` assumes: package repositories, the operator and Terraform
# users, the TerraformProv role and API token, resource pools with their ACLs,
# the Debian LXC template, and the VM templates every machine clones. Every
# step checks what exists first, so a second run changes nothing. Values that
# belong in tfvars are printed at the end. Secrets are never written to a file
# or logged: the operator password is read from the terminal and piped to
# chpasswd, and the API token secret is shown once by Proxmox and left to you.
#
# Usage: bash pve-bootstrap.sh [--dry-run] [step ...]
#
# Steps (default: all, in this order):
#   repos  users  pools  lxc-template  ubuntu-template  talos-template
set -euo pipefail

# ---- settings (override from the environment) ------------------------------

TALOS_VERSION="${TALOS_VERSION:-v1.14.2}"
TALOS_SCHEMATIC="${TALOS_SCHEMATIC:-ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-noble}"
UBUNTU_TEMPLATE_VMID="${UBUNTU_TEMPLATE_VMID:-5000}"
TALOS_TEMPLATE_VMID="${TALOS_TEMPLATE_VMID:-5001}"
ADMIN_USER="${ADMIN_USER:-}"
POOLS="${POOLS:-VM Ubuntu-K8s LXC Talos-K8s}"
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
CACHE_DIR="${CACHE_DIR:-/var/lib/vz/template/cache}"
ISO_DIR="${ISO_DIR:-/var/lib/vz/template/iso}"
STORAGE="${STORAGE:-local-lvm}"

TF_USER="terraform@pve"
TF_ROLE="TerraformProv"
TF_TOKEN="terraform"
TF_PRIVS="VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit \
VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network \
VM.Config.Options VM.Monitor VM.Audit VM.PowerMgmt \
Datastore.AllocateSpace Datastore.Audit"

ALL_STEPS=(repos users pools lxc-template ubuntu-template talos-template)

DRY_RUN=0
CREATED=()
CHANGED=()
SKIPPED=()
TFVARS=()

# ---- helpers ---------------------------------------------------------------

die() {
  echo "error: $*" >&2
  exit 1
}

# Run a command, or print it under --dry-run. Read-only checks bypass this.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "+ $*"
  else
    "$@"
  fi
}

note_created() { CREATED+=("$1"); }
note_changed() { CHANGED+=("$1"); }
note_skipped() { SKIPPED+=("$1"); }

vm_exists() { qm config "$1" > /dev/null 2>&1; }

vm_is_template() { qm config "$1" 2> /dev/null | grep -q '^template: 1'; }

# True when one line of the ACL list holds PATH, USER and ROLE as fields.
has_acl() {
  pveum acl list --noborder 1 | awk -v p="$1" -v u="$2" -v r="$3" '
    { a = b = c = 0
      for (i = 1; i <= NF; i++) {
        if ($i == p) a = 1
        if ($i == u) b = 1
        if ($i == r) c = 1
      }
      if (a && b && c) found = 1 }
    END { exit !found }'
}

ensure_acl() {
  local path="$1" user="$2" role="$3"
  if has_acl "$path" "$user" "$role"; then
    note_skipped "acl $path $user $role"
  else
    run pveum aclmod "$path" -user "$user" -role "$role"
    note_created "acl $path $user $role"
  fi
}

join_by_comma() {
  local IFS=,
  echo "$*" | sed 's/,/, /g'
}

# ---- preflight -------------------------------------------------------------

preflight() {
  local node
  [ "$(id -u)" -eq 0 ] || die "must run as root"
  command -v pveversion > /dev/null 2>&1 || die "this is not a Proxmox host"
  node="$(hostname -s)"
  if [ "$node" != "pve" ]; then
    echo "warning: node is '$node', every tfvars file assumes 'pve'" >&2
  fi
}

# ---- steps -----------------------------------------------------------------

step_repos() {
  local ent="$APT_SOURCES_DIR/pve-enterprise.sources"
  local nosub="$APT_SOURCES_DIR/pve-no-subscription.sources"
  local changed=0

  if [ -f "$ent" ] && ! grep -q '^Enabled: false$' "$ent"; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "+ set 'Enabled: false' in $ent"
    else
      sed -i -e '/^Enabled:/d' "$ent"
      # keep the field inside the stanza: drop trailing blank lines first
      sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$ent"
      [ -z "$(tail -c1 "$ent")" ] || echo >> "$ent"
      echo "Enabled: false" >> "$ent"
    fi
    note_changed "disabled pve-enterprise repository"
    changed=1
  else
    note_skipped "pve-enterprise repository"
  fi

  if [ ! -f "$nosub" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "+ write $nosub"
    else
      cat > "$nosub" << 'SRC'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
SRC
    fi
    note_created "pve-no-subscription repository"
    changed=1
  else
    note_skipped "pve-no-subscription repository"
  fi

  if [ "$changed" -eq 1 ]; then
    run apt update
  fi
}

step_users() {
  local user="$ADMIN_USER" pw1="" pw2=""

  if [ -z "$user" ] && [ -t 0 ]; then
    read -rp "Admin username to create: " user
  fi

  if [ -z "$user" ]; then
    note_skipped "admin user (no ADMIN_USER and no terminal)"
  else
    if ! id "$user" > /dev/null 2>&1; then
      if [ "$DRY_RUN" -eq 0 ]; then
        read -rsp "Password for $user: " pw1
        [ ! -t 0 ] || echo >&2
        read -rsp "Repeat password: " pw2
        [ ! -t 0 ] || echo >&2
        if [ -z "$pw1" ] || [ "$pw1" != "$pw2" ]; then
          pw1="" pw2=""
          die "passwords are empty or do not match"
        fi
      fi
      if ! command -v sudo > /dev/null 2>&1; then
        run apt-get install -y sudo
      fi
      run useradd -m -s /bin/bash -G sudo "$user"
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "+ chpasswd (password read from the terminal)"
      else
        printf '%s:%s\n' "$user" "$pw1" | chpasswd
      fi
      pw1="" pw2=""
      unset pw1 pw2
      note_created "linux user $user"
    else
      note_skipped "linux user $user"
    fi

    if pvesh get "/access/users/$user@pam" > /dev/null 2>&1; then
      note_skipped "pve user $user@pam"
    else
      run pveum user add "$user@pam" -comment "$user admin"
      note_created "pve user $user@pam"
    fi
    ensure_acl / "$user@pam" Administrator
  fi

  if pvesh get "/access/users/$TF_USER" > /dev/null 2>&1; then
    note_skipped "pve user $TF_USER"
  else
    run pveum user add "$TF_USER" -comment Terraform
    note_created "pve user $TF_USER"
  fi

  if pvesh get "/access/roles/$TF_ROLE" > /dev/null 2>&1; then
    run pveum role modify "$TF_ROLE" -privs "$TF_PRIVS"
    note_changed "role $TF_ROLE privileges"
  else
    run pveum role add "$TF_ROLE" -privs "$TF_PRIVS"
    note_created "role $TF_ROLE"
  fi
  ensure_acl / "$TF_USER" "$TF_ROLE"

  if pvesh get "/access/users/$TF_USER/token/$TF_TOKEN" > /dev/null 2>&1; then
    echo "token $TF_USER!$TF_TOKEN already exists; Proxmox cannot show its secret again." >&2
    echo "to rotate: pveum user token remove $TF_USER $TF_TOKEN, then re-run this step." >&2
    note_skipped "token $TF_USER!$TF_TOKEN"
  else
    echo "Creating API token. The secret below is shown once; copy it into pm_api_token_secret."
    run pveum user token add "$TF_USER" "$TF_TOKEN" --privsep 0
    note_created "token $TF_USER!$TF_TOKEN"
  fi
  TFVARS+=("pm_api_token_id = \"$TF_USER!$TF_TOKEN\"")
}

step_pools() {
  local pool
  local -a pools
  read -ra pools <<< "$POOLS"
  for pool in "${pools[@]}"; do
    if pvesh get "/pools/$pool" > /dev/null 2>&1; then
      note_skipped "pool $pool"
    else
      run pveum pool add "$pool"
      note_created "pool $pool"
    fi
    ensure_acl "/pool/$pool" "$TF_USER" "$TF_ROLE"
  done
}

step_lxc_template() {
  local name
  run pveam update
  name="$(pveam available --section system | awk '{print $2}' \
    | grep '^debian-13-standard_' | sort -V | tail -n 1 || true)"
  [ -n "$name" ] || die "no debian-13-standard template in pveam available"
  if pveam list local | grep -qF "$name"; then
    note_skipped "lxc template $name"
  else
    run pveam download local "$name"
    note_created "lxc template $name"
  fi
  TFVARS+=("debian_lxc_template = \"local:vztmpl/$name\"")
}

# Print the volume `qm importdisk` left as unused0 on vmid $1 (the value up to
# the first comma). Under --dry-run nothing was imported, so assume the name
# Proxmox gives the first disk.
unused_volume() {
  local id="$1" cfg vol
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "$STORAGE:vm-$id-disk-0"
    return 0
  fi
  cfg="$(qm config "$id")"
  vol="$(printf '%s\n' "$cfg" | sed -n 's/^unused0: *//p' | head -n 1)"
  vol="${vol%%,*}"
  [ -n "$vol" ] || die "no unused disk on vmid $id after importdisk"
  echo "$vol"
}

# Return 0 to skip (exists and is a template), 1 to build, die otherwise.
template_present() {
  local id="$1" varname="$2"
  vm_exists "$id" || return 1
  vm_is_template "$id" \
    || die "vmid $id exists but is not a template; remove it or pick another $varname"
  return 0
}

step_ubuntu_template() {
  local id="$UBUNTU_TEMPLATE_VMID" rel="$UBUNTU_RELEASE" vol
  local image="$rel-server-cloudimg-amd64.img"
  local base="https://cloud-images.ubuntu.com/$rel/current"
  local img="$CACHE_DIR/$image" sums="$CACHE_DIR/SHA256SUMS" line

  if template_present "$id" UBUNTU_TEMPLATE_VMID; then
    note_skipped "ubuntu template $id"
    TFVARS+=("clone_template_ubuntu = \"ubuntu-cid-tp\"")
    return 0
  fi

  run apt-get install -y libguestfs-tools
  run mkdir -p "$CACHE_DIR"
  run wget -q -O "$img" "$base/$image"
  run wget -q -O "$sums" "$base/SHA256SUMS"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "+ verify $image against SHA256SUMS"
  else
    line="$(grep -F " *$image" "$sums" || true)"
    if [ -z "$line" ] || ! (cd "$CACHE_DIR" && printf '%s\n' "$line" | sha256sum -c - > /dev/null 2>&1); then
      rm -f "$img" "$sums"
      die "checksum mismatch for $image; downloaded files deleted"
    fi
  fi

  run virt-customize -a "$img" --install qemu-guest-agent
  run qm create "$id" --memory 2048 --cores 2 --name ubuntu-cid-tp
  run qm importdisk "$id" "$img" "$STORAGE"
  vol="$(unused_volume "$id")"
  run qm set "$id" --scsihw virtio-scsi-pci --scsi0 "$vol"
  run qm set "$id" --ide2 "$STORAGE:cloudinit"
  run qm set "$id" --boot c --bootdisk scsi0
  run qm set "$id" --serial0 socket --vga serial0
  run qm template "$id"
  run rm -f "$img" "$sums"
  note_created "ubuntu template $id (ubuntu-cid-tp)"
  TFVARS+=("clone_template_ubuntu = \"ubuntu-cid-tp\"")
}

step_talos_template() {
  local id="$TALOS_TEMPLATE_VMID" vol
  local xzfile="$ISO_DIR/talos-nocloud.raw.xz" raw="$ISO_DIR/talos-nocloud.raw"

  if template_present "$id" TALOS_TEMPLATE_VMID; then
    note_skipped "talos template $id"
    return 0
  fi

  run mkdir -p "$ISO_DIR"
  run wget -q -O "$xzfile" \
    "https://factory.talos.dev/image/$TALOS_SCHEMATIC/$TALOS_VERSION/nocloud-amd64.raw.xz"
  echo "note: Image Factory publishes no checksum for this image (the schematic id is content-addressed); no checksum verified."
  run xz -d "$xzfile"
  run qm create "$id" --name talos-tp --memory 2048 --cores 2 --cpu x86-64-v2-AES \
    --machine q35 --ostype l26 --scsihw virtio-scsi-single \
    --net0 virtio,bridge=vmbr0 --serial0 socket --agent enabled=1
  run qm importdisk "$id" "$raw" "$STORAGE"
  vol="$(unused_volume "$id")"
  run qm set "$id" --scsi0 "$vol,discard=on,iothread=1,ssd=1" --boot order=scsi0 \
    --ide2 "$STORAGE:cloudinit"
  run qm template "$id"
  run rm -f "$raw"
  note_created "talos template $id (talos-tp)"
}

# ---- summary and main ------------------------------------------------------

summary() {
  local v
  echo
  echo "created: $(join_by_comma "${CREATED[@]+"${CREATED[@]}"}")"
  echo "changed: $(join_by_comma "${CHANGED[@]+"${CHANGED[@]}"}")"
  echo "skipped: $(join_by_comma "${SKIPPED[@]+"${SKIPPED[@]}"}")"
  if [ "${#TFVARS[@]}" -gt 0 ]; then
    echo
    echo "== values for tfvars =="
    for v in "${TFVARS[@]}"; do
      echo "$v"
    done
  fi
}

usage() {
  cat << 'USAGE'
usage: bash pve-bootstrap.sh [--dry-run] [step ...]

steps (default: all, in this order):
  repos  users  pools  lxc-template  ubuntu-template  talos-template

--dry-run  print the commands that would change something, change nothing
-h, --help show this help
USAGE
}

main() {
  local -a steps=()
  local arg s known

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      -h | --help)
        usage
        return 0
        ;;
      *) steps+=("$1") ;;
    esac
    shift
  done
  [ "${#steps[@]}" -gt 0 ] || steps=("${ALL_STEPS[@]}")

  for arg in "${steps[@]}"; do
    known=0
    for s in "${ALL_STEPS[@]}"; do
      [ "$arg" = "$s" ] && known=1
    done
    if [ "$known" -eq 0 ]; then
      echo "unknown step '$arg'; valid steps: ${ALL_STEPS[*]}" >&2
      return 1
    fi
  done

  preflight

  for arg in "${steps[@]}"; do
    echo "== $arg =="
    "step_${arg//-/_}"
  done
  summary
}

main "$@"
