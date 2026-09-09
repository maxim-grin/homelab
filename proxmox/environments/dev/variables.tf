variable "project" {
  description = "Proxmox Project Name"
  type        = string
}

variable "environment" {
  description = "Environment Name"
  type        = string

  # validation {
  #   condition     = var.environment == terraform.workspace
  #   error_message = "Workspace & Variable File Inconsistency!! Please Double Check!!"
  # }
}

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

# Ubuntu VM variables
# Cloud-init
variable "ci_user" {
  description = "Cloud-init user"
  type        = string
}

variable "ci_password" {
  description = "Cloud-init password"
  type        = string
  sensitive   = true
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for adding it to autorized key"
  type        = string
  default     = ""
}

variable "clone_template_ubuntu" {
  description = "Template name for general Ubuntu VMs (ubuntu-cid-tp or similar)"
  type        = string
}

variable "clone_template_k8s" {
  description = "Template name for Ubuntu K8s base VMs"
  type        = string
}

variable "debian_os_template" {
  description = "OS template for Debian distro"
  type        = string
}

# ubuntu VM variables
variable "ub_ip_config" {
  description = "ubuntu VM IP configuration (ipconfig0)"
  type        = string
}

variable "ub_vm_ip" {
  description = "ubuntu VM IP address (for provisioners)"
  type        = string
}

# ubuntu-2 VM variables
variable "ub_2_ip_config" {
  description = "ubuntu-2 VM IP configuration (ipconfig0)"
  type        = string
}

variable "ub_2_vm_ip" {
  description = "ubuntu-2 VM IP address (for provisioners)"
  type        = string
}

# Ubuntu-K8s Variables
variable "gateway" {
  description = "LXC Container Gateway"
  type        = string
}

variable "ub_k8s_cidr" {
  description = "ubuntu VM IP configuration (ipconfig0)"
  type        = string
}

# LXC Container Variables (for n8n)
variable "lxc_pass" {
  description = "LXC Container Password"
  type        = string
  sensitive   = true
}

variable "n8n_ip" {
  description = "n8n Container IP"
  type        = string
  default     = "dhcp"
}

# Claude Code VM Variables
variable "claude_code_ip" {
  description = "Claude Code VM IP with CIDR (e.g. '10.0.0.130/24')"
  type        = string
}

# NFS Server VM Variables
variable "nfs_vm_ip" {
  description = "NFS server VM IP with CIDR (e.g. '10.0.0.131/24')"
  type        = string
}
