output "vm_id" {
  description = "The VM's Proxmox ID"
  value       = proxmox_vm_qemu.node.vmid
}

output "vm_name" {
  description = "The VM's name"
  value       = proxmox_vm_qemu.node.name
}

output "ip" {
  description = "The static address this node is configured with"
  value       = var.ip
}
