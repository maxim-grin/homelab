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
module "vault_vm" {
  source = "../../modules/vault-vm"

  # Basic VM Configuration
  vm_name     = "vault-02"
  vmid        = 105
  target_node = var.pm_target_node
  pool        = "VM"

  clone_template = var.clone_template_ubuntu
  full_clone     = true

  # Resource Allocation
  # Raft plus a handful of KV paths. The LXC it replaces ran in 1 GiB; the
  # extra gigabyte is headroom for the audit log and snapshot runs.
  memory    = 2048
  cpu_cores = 2

  # OS disk, then the Raft store on its own disk.
  disk_size            = "20G"
  vault_data_disk_size = "10G"
  disk_storage         = "local-lvm"

  # First up, ahead of nfs-01 at order=10 and the cluster at 20/30. Vault is
  # the root of trust: when it is sealed or absent, argocd-vault-plugin
  # renders nothing and every Application carrying a <path:...> placeholder
  # fails to sync.
  start_at_node_boot = true
  startup            = "order=5,up=20"

  # Network Configuration
  network_firewall = true
  ip_config        = format("ip=%s,gw=%s", var.vault_vm_ip, var.gateway)

  # Cloud-init Settings
  ci_user        = var.ci_user
  ci_password    = var.ci_password
  ssh_public_key = var.ssh_public_key

  # OS configuration lives in the ansible/ vault role, run against
  # ansible/inventories/shared. This VM is empty until that runs; the
  # vault-01 LXC keeps serving until then.

  # Tags
  tags = "ubuntu,vault,shared"
}
