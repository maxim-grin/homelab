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

# Vault VM Variables
variable "vault_vm_ip" {
  description = "Vault VM IP with CIDR (e.g. '10.0.0.133/24')"
  type        = string
}

# One address per LAN service, keyed by the names in local.lan_services
# in main.tf. Each must include the prefix length, e.g. "10.0.0.140/24".
variable "lxc_ips" {
  description = "Static address with prefix for each LAN service container"
  type        = map(string)

  validation {
    condition = alltrue([
      for name in ["pihole", "traefik", "glance", "gatus", "orangutan"] :
      can(regex("^10\\.0\\.0\\.[0-9]+/24$", lookup(var.lxc_ips, name, "")))
    ])
    error_message = "lxc_ips needs pihole, traefik, glance, gatus and orangutan, each as 10.0.0.N/24."
  }
}

# Must already be downloaded on the host: pveam update, then
# pveam download local <file>. See docs/rebuild.md.
variable "debian_lxc_template" {
  description = "Debian 13 LXC template, e.g. local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
  type        = string
}
