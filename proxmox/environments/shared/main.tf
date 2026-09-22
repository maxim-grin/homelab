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

# Adopts the existing nfs-01 instead of creating a new one. Remove this block
# once the first apply has imported it: on a rebuilt host vmid 103 does not
# exist yet, and an import of a missing VM fails the plan.
import {
  to = module.nfs.proxmox_vm_qemu.nfs_server
  id = "${var.pm_target_node}/qemu/103"
}
