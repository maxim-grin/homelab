# Mock provider: nothing here reaches Proxmox. This root holds only the
# claude-code workstation VM (ADR 0034).
mock_provider "proxmox" {}

variables {
  pm_api_url           = "https://pve.invalid:8006/api2/json"
  pm_api_token_id      = "terraform@pve!test"
  pm_api_token_secret  = "not-a-secret"
  pm_target_node       = "pve"
  ci_user              = "test"
  ci_password          = "<PASSWORD>"
  gateway              = "192.0.2.1"
  project              = "homelab"
  environment          = "dev"
  ssh_private_key_path = "/dev/null"
  # Not a CIDR on purpose: an ubuntu-k8s module in this root fails to plan on
  # it, so the dev cluster cannot come back without changing this test.
  ub_k8s_cidr           = "unused"
  clone_template_k8s    = "tmpl"
  clone_template_ubuntu = "tmpl"
  claude_code_ip        = "192.0.2.130/24"
}

run "claude_code_stays" {
  command = plan

  assert {
    condition     = output.claude_code_vm_details.name == "claude-code" && output.claude_code_vm_details.id == 102
    error_message = "this root must plan claude-code, vmid 102"
  }
}
