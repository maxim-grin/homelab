################################################################################
# Shared infrastructure: machines no single environment owns.
#
# nfs-01 serves both nfs-dev and nfs-prod, so neither environment's apply may
# change or destroy it. It lived in environments/dev until 2026-09 and was
# adopted here with an import block; dev dropped it with a removed block.
################################################################################

################################################################################
# NFS Server
################################################################################
module "nfs" {
  source = "../../modules/nfs-server"

  # Basic VM Configuration
  vm_name     = "nfs"
  vmid        = 103
  target_node = var.pm_target_node
  pool        = "VM"

  clone_template = var.clone_template_ubuntu
  full_clone     = true

  # Resource Allocation
  # It only serves files; nfsd is kernel-side and needs almost nothing here.
  memory    = 2048
  cpu_cores = 2

  # OS disk, then one disk per share. nfs-subdir-external-provisioner does
  # not enforce PVC sizes, so a share can grow until its disk is full; 50G
  # covers what the dev PVCs request today.
  disk_size          = "20G"
  nfs_dev_disk_size  = "50G"
  nfs_prod_disk_size = "50G"
  disk_storage       = "local-lvm"

  # Start automatically: every PVC in every cluster binds through this host.
  # Order 10, ahead of the dev cluster (master order=20, workers order=30 in
  # environments/dev): when the provisioner is down every PVC without an
  # explicit class sits Pending and the apps above it read as broken for
  # unrelated reasons.
  start_at_node_boot = true
  startup            = "order=10,up=30"

  # Network Configuration
  network_firewall = true
  ip_config        = format("ip=%s,gw=%s", var.nfs_vm_ip, var.gateway)

  # Cloud-init Settings
  ci_user        = var.ci_user
  ci_password    = var.ci_password
  ssh_public_key = var.ssh_public_key

  # OS configuration lives in the ansible/ nfs_server role, run against
  # ansible/inventories/shared.

  # Tags
  tags = "ubuntu,nfs,shared"
}

################################################################################
# HashiCorp Vault
################################################################################
module "vault" {
  source = "../../modules/lxc"

  vmid        = 104
  target_node = var.pm_target_node
  hostname    = "vault"
  ostemplate  = var.debian_os_template
  password    = var.lxc_pass
  # The LXC pool and its TerraformProv ACL on /pool/LXC were created by hand
  # on the host; Terraform does not create pools and terraform@pve carries no
  # Pool.* privileges. Placement into a pool without that ACL fails with a
  # permission error that never mentions pools.
  pool         = "LXC"
  unprivileged = true

  ssh_public_keys = var.ssh_public_key

  # A file-backed Vault with a handful of KV paths needs almost nothing.
  # Matches the known-working vault_lxc block in environments/prod.
  cores  = 1
  memory = 1024
  swap   = 0

  rootfs_storage = "local-lvm"
  rootfs_size    = "8G"

  network_bridge = "vmbr0"
  network_ip     = var.vault_lxc_ip
  network_gw     = var.gateway

  # First up, ahead of nfs-01 at order=10. Vault is the root of trust: when it
  # is sealed or absent, argocd-vault-plugin renders nothing and every
  # Application carrying a <path:...> placeholder fails to sync.
  start              = true
  start_at_node_boot = true
  startup            = "order=5,up=20"

  # No nesting, fuse, keyctl or mount. environments/prod sets nesting = true
  # on its vault container -- but it sets it on all five of its containers
  # identically, so that is a blanket habit, not evidence Vault needs it.
  # Proxmox documents nesting as exposing host procfs and sysfs to the guest.
  # If vault.service will not start even with the drop-in from Task 2, adding
  # nesting here is the documented fallback; do not reach for it first.
  features_enabled = false

  tags = "lxc,vault,shared"
}

# Adopts the existing vault-01 instead of creating a new one. Remove this
# block once the first apply has imported it: on a rebuilt host vmid 104 does
# not exist yet, and an import of a missing container fails the plan.
import {
  to = module.vault.proxmox_lxc.lxc_container
  id = "${var.pm_target_node}/lxc/104"
}
