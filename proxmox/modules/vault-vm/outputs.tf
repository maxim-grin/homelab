output "vm_id" {
  description = "The ID of the Vault VM"
  value       = proxmox_vm_qemu.vault_vm.vmid
}

output "vm_name" {
  description = "The name of the Vault VM"
  value       = proxmox_vm_qemu.vault_vm.name
}

output "vm_mac" {
  description = "The MAC address of the VM's network interface"
  value       = proxmox_vm_qemu.vault_vm.network[0].macaddr
}

output "vm_ip_config" {
  description = "The IP configuration of the VM"
  value       = proxmox_vm_qemu.vault_vm.ipconfig0
}
