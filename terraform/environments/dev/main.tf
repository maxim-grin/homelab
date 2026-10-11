################################################################################
# Dev K8s Cluster
################################################################################

# Replaces the old three-node "dev-cluster" (cluster_id 2: vmids 2101, 2201,
# 2202). That block was removed, not renamed, so there is deliberately no
# `moved` block (ADR 0013 covers renames): the destroy is the intent.
#
# Host RAM is fully committed, so the old cluster goes first. The operator:
#   1. terraform plan -target=module.dev-cluster -var-file=dev.tfvars
#      (a target for an address in state but gone from config plans only
#      its destroy). The summary must show exactly 3 to destroy, 0 to add,
#      0 to change. Then the same command with `apply`.
#   2. terraform apply -var-file=dev.tfvars
#      The plan must show exactly 2 to add (the two VMs; provisioners are
#      off), 0 to change and 0 to destroy.
# Read each plan before applying; an unexpected destroy is a stop.
#
# cluster_id 4 gives vmids 4101 and 4201 (3 is prod); check `qm list` for
# them first. The nodes reuse the old addresses, .101 and .201: the old
# nodes are destroyed before these exist, and nothing else holds them.
module "kubeadm-dev" {
  source = "../../modules/ubuntu-k8s"

  target_node = var.pm_target_node

  cluster_id   = 4
  cluster_name = "kubeadm-dev"
  pool         = "Ubuntu-K8s"

  # kubeadm-dev-cp1 and kubeadm-dev-w1
  master_name_format = "%s-cp%d"
  worker_name_format = "%s-w%d"

  master_count = 1
  worker_count = 1

  network_cidr = var.ub_k8s_cidr
  gateway      = var.gateway

  clone_template = var.clone_template_k8s
  # Cloud-init Settings
  ci_user              = var.ci_user
  ci_password          = var.ci_password
  ssh_private_key_path = var.ssh_private_key_path
  ssh_public_key       = var.ssh_public_key


  # 3 GiB each (the old cluster had 4G/3G/3G): host RAM is full. A memory
  # change reboots the VM (automatic_reboot defaults to true), so a plain
  # apply reboots every node at once; apply one node at a time, drained
  # first, with -target='module.kubeadm-dev.module.nodes["worker-01"]'.
  master_memory = 3072
  worker_memory = 3072

  # 30G, not the module's 10G default. On 10G disks /var/lib/containerd
  # alone reached 3.8G and kubelet crossed its ephemeral-storage threshold
  # whenever a new image was pulled: worker-02 flapped in and out of
  # DiskPressure six times in nine days, evicting argocd-repo-server and
  # harbor-jobservice pods on the old nodes. Raising this only grows the
  # virtual disk -- growpart and resize2fs inside each guest do the rest --
  # and it can never be lowered again.
  master_disk_size = "30G"
  worker_disk_size = "30G"

  # Come back after a host power loss. Without this the module defaulted to
  # false and the entire cluster stayed down on 2026-09-10 while nfs-01 and
  # claude-code-01, which set it, returned on their own.
  start_at_node_boot = true

  # Master ahead of the workers, with 60s for the API server to answer before
  # kubelets start trying to reach it. Both after nfs-01 at order=10, which
  # lives in terraform/environments/shared.
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
  # 4 GiB: 8 GiB left the host with no page cache (32 GiB total, all
  # VMs summed to 32 GiB); this VM uses under 2 GiB in practice.
  memory    = 4096
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
