# Ubuntu K8s Cluster Ouputs
output "master_nodes" {
  description = "Details for all master nodes."
  value       = module.dev-cluster.master_nodes
}

output "worker_nodes" {
  description = "Details for all worker nodes."
  value       = module.dev-cluster.worker_nodes
}

output "all_node_vmids" {
  description = "Map of logical node names to assigned VMIDs."
  value       = module.dev-cluster.all_node_vmids
}

# Claude Code VM Output
output "claude_code_vm_details" {
  value = {
    id   = module.claude_code.vm_id
    name = module.claude_code.vm_name
    mac  = module.claude_code.vm_mac
    ip   = module.claude_code.vm_ip_config
  }
}
