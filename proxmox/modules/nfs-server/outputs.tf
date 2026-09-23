output "vm_id" {
  description = "The ID of the NFS server VM"
  value       = proxmox_vm_qemu.nfs_server.vmid
}

output "vm_name" {
  description = "The name of the NFS server VM"
  value       = proxmox_vm_qemu.nfs_server.name
}

output "vm_mac" {
  description = "The MAC address of the VM's network interface"
  value       = proxmox_vm_qemu.nfs_server.network[0].macaddr
}

output "vm_ip_config" {
  description = "The IP configuration of the VM"
  value       = proxmox_vm_qemu.nfs_server.ipconfig0
}
