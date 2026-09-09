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
  # 60G, not 30G: cloned repos plus npm/uv caches and node_modules fill
  # 30G quickly on a box whose whole job is checking out other projects.
  disk_size    = "20G"
  disk_storage = "local-lvm"

  # Start automatically
  start_at_node_boot = true

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
  start_at_node_boot = true

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

