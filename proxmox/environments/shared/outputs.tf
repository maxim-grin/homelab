# NFS Server VM Output
output "nfs_vm_details" {
  value = {
    id   = module.nfs.vm_id
    name = module.nfs.vm_name
    mac  = module.nfs.vm_mac
    ip   = module.nfs.vm_ip_config
  }
}
