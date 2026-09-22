# ProxMox Variables
variable "pm_target_node" {
  description = "Proxmox Target Node"
  type        = string
}

variable "pm_api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "pm_api_token_id" {
  description = "Proxmox API Token ID"
  type        = string
}

variable "pm_api_token_secret" {
  description = "Proxmox API Token Secret"
  type        = string
}

# Cloud-init. Must match dev.tfvars: nfs-01 was created with these values,
# and a different password or key shows up as drift on the imported VM.
variable "ci_user" {
  description = "Cloud-init user"
  type        = string
}

variable "ci_password" {
  description = "Cloud-init password"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for adding it to authorized keys"
  type        = string
  default     = ""
}

variable "clone_template_ubuntu" {
  description = "Ubuntu cloud-init template every VM clones"
  type        = string
}

variable "gateway" {
  description = "Default gateway for static IPs"
  type        = string
}

# NFS Server VM Variables
variable "nfs_vm_ip" {
  description = "NFS server VM IP with CIDR (e.g. '10.0.0.131/24')"
  type        = string
}
