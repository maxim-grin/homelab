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

  # 30G, not the module's 10G default. On 10G disks /var/lib/containerd
  # alone reached 3.8G and kubelet crossed its ephemeral-storage threshold
  # whenever a new image was pulled: worker-02 flapped in and out of
  # DiskPressure six times in nine days, evicting argocd-repo-server and
  # harbor-jobservice pods. Raising this only grows the virtual disk --
  # growpart and resize2fs inside each guest do the rest -- and it can
  # never be lowered again.
  master_disk_size = "30G"
  worker_disk_size = "30G"

  # Come back after a host power loss. Without this the module defaulted to
  # false and the entire cluster stayed down on 2026-09-10 while nfs-01 and
  # claude-code-01, which set it, returned on their own.
  start_at_node_boot = true

  # Master ahead of the workers, with 60s for the API server to answer before
  # kubelets start trying to reach it. Both after nfs-01 at order=10, which
  # lives in proxmox/environments/shared.
  master_startup = "order=20,up=60"
  worker_startup = "order=30"
}

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

# nfs-01 (vmid 103) lives in proxmox/environments/shared.

################################################################################
# HashiCorp Vault -- moved to environments/shared
################################################################################
# vault-01 is the root of trust for both clusters, so it is owned by
# proxmox/environments/shared. destroy = false drops it from this state
# without touching the container. Delete this block once `terraform apply`
# here has run with it once.
removed {
  from = module.vault

  lifecycle {
    destroy = false
  }
}
