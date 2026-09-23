# VM Basic Configuration
variable "vm_name" {
  description = "Name of the VM"
  type        = string
}

variable "target_node" {
  description = "Proxmox node to deploy VM on"
  type        = string
}

variable "vmid" {
  description = "VM ID (must be unique)"
  type        = number
}

variable "pool" {
  description = "Resource pool for the VM"
  type        = string
  default     = null
}

# Clone Configuration
variable "clone_template" {
  description = "Template to clone from"
  type        = string
}

variable "full_clone" {
  description = "Whether to perform a full clone"
  type        = bool
}

# Resource Allocation
variable "memory" {
  description = "Memory allocation in MB"
  type        = number
}

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
}

# Boot Configuration
variable "start_at_node_boot" {
  description = "Start VM on boot"
  type        = bool
}

# Proxmox startup order. Guests start low-order first; "up" is the delay in
# seconds before the next one begins. Every PVC in every cluster binds
# through this host, so it starts ahead of them.
variable "startup" {
  description = "Startup order and delay (e.g., 'order=10,up=30')"
  type        = string
  default     = null
}

# Disk Configuration
variable "disk_size" {
  description = "OS disk size (e.g., '20G')"
  type        = string
}

# One disk per share, so one environment filling its share cannot stop the
# other writing. Sizes only go up: Proxmox cannot shrink a disk.
variable "nfs_dev_disk_size" {
  description = "Size of the nfs-dev data disk (scsi1)"
  type        = string
}

variable "nfs_prod_disk_size" {
  description = "Size of the nfs-prod data disk (scsi2)"
  type        = string
}

variable "disk_storage" {
  description = "Storage location for all three disks"
  type        = string
  default     = "local-lvm"
}

variable "cloudinit_storage" {
  description = "Storage for cloud-init disk"
  type        = string
  default     = "local-lvm"
}

# Network Configuration
variable "network_bridge" {
  description = "Network bridge"
  type        = string
  default     = "vmbr0"
}

variable "network_firewall" {
  description = "Enable firewall on network interface"
  type        = bool
  default     = true
}

# Cloud-init Settings
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

variable "ip_config" {
  description = "IP configuration (ipconfig0)"
  type        = string
}

# Tags
variable "tags" {
  description = "VM tags"
  type        = string
  default     = "ubuntu,nfs"
}
