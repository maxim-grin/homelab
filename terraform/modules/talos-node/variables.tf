variable "vm_name" {
  description = "VM name, also the node's hostname (Proxmox cloud-init passes it to Talos)"
  type        = string
}

variable "target_node" {
  description = "Proxmox node to deploy on"
  type        = string
}

variable "vmid" {
  description = "VM ID (must be unique on the host)"
  type        = number
}

variable "pool" {
  description = "Resource pool; terraform@pve needs TerraformProv on it"
  type        = string
}

variable "clone_template" {
  description = "Template to full-clone (the Talos nocloud image)"
  type        = string
}

variable "memory" {
  description = "Memory in MiB. Talos's documented minimum is 2048"
  type        = number
}

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "disk_size" {
  description = "Boot disk size; the Talos image grows its EPHEMERAL partition to fill it"
  type        = string
  default     = "20G"
}

variable "disk_storage" {
  description = "Storage for the boot disk"
  type        = string
  default     = "local-lvm"
}

variable "cloudinit_storage" {
  description = "Storage for the cloud-init drive"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Bridge the node attaches to"
  type        = string
  default     = "vmbr0"
}

variable "network_firewall" {
  description = "Enable the Proxmox firewall on the interface"
  type        = bool
  default     = false
}

variable "ip" {
  description = "Static IPv4 address, without a prefix length"
  type        = string
}

variable "prefix_length" {
  description = "Prefix length of the LAN, e.g. 24"
  type        = number
  default     = 24
}

variable "gateway" {
  description = "Default gateway"
  type        = string
}

variable "nameserver" {
  description = "DNS server handed to Talos through cloud-init"
  type        = string
  default     = "1.1.1.1"
}

variable "start_at_node_boot" {
  description = "Start the VM when the Proxmox host boots"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Proxmox tags"
  type        = string
  default     = "talos,prod"
}
