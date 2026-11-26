# The kubeadm dev cluster was destroyed (ADR 0034). This root holds only
# claude-code, the operator's workstation: never run `terraform destroy` here.

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
