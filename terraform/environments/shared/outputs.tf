# NFS Server VM Output
output "nfs_vm_details" {
  value = {
    id   = module.nfs.vm_id
    name = module.nfs.vm_name
    mac  = module.nfs.vm_mac
    ip   = module.nfs.vm_ip_config
  }
}

# Vault VM Output
output "vault_vm_details" {
  value = {
    id   = module.vault_vm.vm_id
    name = module.vault_vm.vm_name
    mac  = module.vault_vm.vm_mac
    ip   = module.vault_vm.vm_ip_config
  }
}
