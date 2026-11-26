# Claude Code VM Output
output "claude_code_vm_details" {
  value = {
    id   = module.claude_code.vm_id
    name = module.claude_code.vm_name
    mac  = module.claude_code.vm_mac
    ip   = module.claude_code.vm_ip_config
  }
}
