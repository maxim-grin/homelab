################################################################################
# General Purpose Dev Ubuntu VM + Jump Host
################################################################################
module "ubuntu_vm_1" {
  source = "../../modules/ubuntu-vm"

  # Basic VM Configuration
  vm_name        = "ubuntu"
  vmid           = 100
  target_node    = var.pm_target_node
  pool           = "VM"
  clone_template = null
  full_clone     = false

  # Resource Allocation
  memory    = 8192
  cpu_cores = 2

  # Disk Configuration
  disk_size    = "20G"
  disk_storage = "local-lvm"

  # Start automatically
  start_at_node_boot = false

  # Qemu Agent
  qemu_agent = 1

  # Network Configuration
  network_firewall = true
  ip_config        = var.ub_ip_config
  vm_ip            = var.ub_vm_ip

  # Cloud-init Settings
  ci_user              = var.ci_user
  ci_password          = var.ci_password
  ssh_private_key_path = var.ssh_private_key_path
  ssh_public_key       = var.ssh_public_key

  # Run provisioner on startup
  enable_provisioners = false

  # Tags
  tags = "ubuntu,dev"
}

module "ubuntu_vm_2" {
  source = "../../modules/ubuntu-vm"

  # Basic VM Configuration
  vm_name        = "ubuntu-2"
  vmid           = 101
  target_node    = var.pm_target_node
  pool           = "VM"
  clone_template = var.clone_template_ubuntu
  full_clone     = true

  # Resource Allocation
  memory    = 4096
  cpu_cores = 2

  # Disk Configuration
  disk_size    = "10G"
  disk_storage = "local-lvm"

  # Start automatically
  start_at_node_boot = false

  # Qemu Agent
  qemu_agent = 1

  # Network Configuration
  network_firewall = true
  ip_config        = var.ub_2_ip_config
  vm_ip            = var.ub_2_vm_ip

  # Cloud-init Settings
  ci_user              = var.ci_user
  ci_password          = var.ci_password
  ssh_private_key_path = var.ssh_private_key_path
  ssh_public_key       = var.ssh_public_key

  # Run provisioner on startup
  enable_provisioners = true

  # Tags
  tags = "ubuntu,dev"
}

################################################################################
# Ubuntu K8s Cluster
################################################################################

module "ubunut-k8s-1" {
  source = "../../modules/ubuntu-k8s"

  target_node = var.pm_target_node

  cluster_id   = 2
  cluster_name = "ubuntu-k8s"
  pool         = "Ubuntu-K8s"

  master_count = 1
  worker_count = 2

  network_cidr = var.ub_k8s_cidr
  gateway      = var.gateway

  clone_template = var.clone_template_k8s
  # Cloud-init Settings
  ci_user              = var.ci_user
  ci_password          = var.ci_password
  ssh_private_key_path = var.ssh_private_key_path
  ssh_public_key       = var.ssh_public_key


  master_memory = 8192
  worker_memory = 4096

  # Come back after a host power loss. Without this the module defaulted to
  # false and the entire cluster stayed down on 2026-09-10 while nfs-01 and
  # claude-code-01, which set it, returned on their own.
  start_at_node_boot = true

  # Master ahead of the workers, with 60s for the API server to answer before
  # kubelets start trying to reach it. Both after nfs-01 at order=10.
  master_startup = "order=20,up=60"
  worker_startup = "order=30"
}

################################################################################
# n8n Workflow Automation (migrated from prod)
################################################################################
# module "n8n" {
#   source = "../../modules/lxc"

#   vmid         = 383
#   target_node  = var.pm_target_node
#   hostname     = "n8n"
#   ostemplate   = var.debian_os_template
#   password     = var.lxc_pass
#   start_at_node_boot       = false
#   unprivileged = true
#   pool         = "LXC"

#   cores  = 2
#   memory = 2048
#   swap   = 0

#   # Storage
#   rootfs_storage = "local-lvm"
#   rootfs_size    = "10G"

#   # Network
#   network_bridge = "vmbr0"
#   network_ip     = var.n8n_ip
#   network_gw     = var.gateway

#   features_enabled = true
#   features = {
#     nesting = true
#   }

#   # Tags
#   tags = "lxc,n8n,dev"
# }

################################################################################
# Claude Code AI Assistant VM
################################################################################
module "claude_code" {
  source = "../../modules/ubuntu-vm"

  # Basic VM Configuration
  vm_name     = "claude-code"
  vmid        = 102
  target_node = var.pm_target_node
  pool        = "VM"

  clone_template = var.clone_template_ubuntu
  full_clone     = true

  # Resource Allocation
  # 4 cores: Claude Code runs ripgrep sweeps and build/test commands
  # concurrently with the agent itself; 2 cores stalls on both.
  memory    = 8192
  cpu_cores = 4

  # Disk Configuration
  # 40G. 20G was measured against a box that only ran Claude Code; it now
  # carries Docker, and postgres:17 plus a python base plus the built image
  # and build cache run to several GB before any repository is cloned.
  # Growing is the safe direction: raise this, apply, and reboot -- the
  # cloud image's cloud-init growpart extends the root partition on boot.
  #
  # Changing this number is not free in either direction. Proxmox cannot
  # shrink a disk: qm resize only grows, the provider's attempt to detach and
  # re-add scsi0 fails with "can't unplug bootdisk 'scsi0'", and the failed
  # apply still writes the smaller value into state, leaving Terraform
  # believing a size the host does not have. Lowering it means
  # `terraform apply -replace` and rebuilding the host from its playbook.
  # Growing works in place but needs growpart and resize2fs in the guest
  # if cloud-init's growpart does not run.
  disk_size    = "40G"
  disk_storage = "local-lvm"

  # Start automatically, last -- nothing depends on it.
  start_at_node_boot = true
  startup            = "order=40"

  # Qemu Agent
  qemu_agent = 1

  # Network Configuration
  network_firewall = true
  ip_config        = format("ip=%s,gw=%s", var.claude_code_ip, var.gateway)
  vm_ip            = split("/", var.claude_code_ip)[0]

  # Cloud-init Settings
  ci_user              = var.ci_user
  ci_password          = var.ci_password
  ssh_private_key_path = var.ssh_private_key_path
  ssh_public_key       = var.ssh_public_key

  # OS configuration lives in the ansible/ claude_code role, not here. The
  # module's remote-exec runs inside a null_resource with no triggers, so it
  # fires once at create and never again -- editing the command list later
  # plans nothing. Toolchain on this host changes often; keep it re-runnable.
  enable_provisioners = false

  # Tags
  tags = "ubuntu,claude-code,dev"
}

################################################################################
# NFS Server
################################################################################
module "nfs" {
  source = "../../modules/ubuntu-vm"

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

  disk_size    = "20G"
  disk_storage = "local-lvm"

  # Start automatically: every PVC in the cluster binds through this host.
  # Order 10, ahead of the cluster: when the provisioner is down every PVC
  # without an explicit class sits Pending and the apps above it read as
  # broken for unrelated reasons.
  start_at_node_boot = true
  startup            = "order=10,up=30"

  # Qemu Agent
  qemu_agent = 1

  # Network Configuration
  network_firewall = true
  ip_config        = format("ip=%s,gw=%s", var.nfs_vm_ip, var.gateway)
  vm_ip            = split("/", var.nfs_vm_ip)[0]

  # Cloud-init Settings
  ci_user              = var.ci_user
  ci_password          = var.ci_password
  ssh_private_key_path = var.ssh_private_key_path
  ssh_public_key       = var.ssh_public_key

  # OS configuration lives in the ansible/ nfs_server role.
  enable_provisioners = false

  # Tags
  tags = "ubuntu,nfs,dev"
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

  tags = "lxc,vault,dev"
}
