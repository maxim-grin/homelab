# Proxmox
variable "pm_api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "pm_api_token_id" {
  description = "Proxmox API token ID"
  type        = string
}

variable "pm_api_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "pm_target_node" {
  description = "Proxmox node the VMs run on"
  type        = string
}

# Network
variable "gateway" {
  description = "Default gateway for the static addresses"
  type        = string
}

variable "prefix_length" {
  description = "Prefix length of the LAN"
  type        = number
  default     = 24
}

variable "nameserver" {
  description = "DNS server handed to the nodes through cloud-init"
  type        = string
  default     = "1.1.1.1"
}

# Cluster
variable "cluster_name" {
  description = "Talos / Kubernetes cluster name; prefixes every VM name"
  type        = string
  default     = "talos-prod"
}

variable "clone_template" {
  description = "Template every node full-clones: the Image Factory nocloud image"
  type        = string
  default     = "talos-tp"
}

variable "pool" {
  description = "Resource pool for the nodes; created by hand, see docs/rebuild.md"
  type        = string
  default     = "Talos-K8s"
}

variable "talos_version" {
  description = "Talos release. Must match the image baked into the template"
  type        = string
  default     = "v1.14.2"
}

variable "talos_schematic_id" {
  description = "Image Factory schematic: nocloud with the qemu-guest-agent extension. Keeps the extension across upgrades"
  type        = string
  default     = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
}

variable "kubernetes_version" {
  description = "Kubernetes version baked into the machine configs; null takes the provider's default for talos_version"
  type        = string
  default     = null
}

variable "node_cores" {
  description = "CPU cores per node"
  type        = number
  default     = 2
}

variable "node_disk_size" {
  description = "Boot disk size per node"
  type        = string
  default     = "20G"
}

variable "talos_nodes" {
  description = "Nodes by short name (cp1, w1, ...). Exactly one controlplane."
  type = map(object({
    role   = string
    vmid   = number
    ip     = string
    memory = number
  }))

  validation {
    condition     = alltrue([for n in values(var.talos_nodes) : contains(["controlplane", "worker"], n.role)])
    error_message = "role must be \"controlplane\" or \"worker\"."
  }

  validation {
    condition     = length([for n in values(var.talos_nodes) : n if n.role == "controlplane"]) == 1
    error_message = "talos_nodes needs exactly one controlplane: the cluster endpoint is that node's address and there is no VIP."
  }

  validation {
    condition     = alltrue([for n in values(var.talos_nodes) : can(cidrhost("${n.ip}/32", 0)) && can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", n.ip))])
    error_message = "ip must be a bare IPv4 address such as 10.0.0.110, with no prefix length."
  }

  validation {
    condition     = length(distinct([for n in values(var.talos_nodes) : n.ip])) == length(var.talos_nodes)
    error_message = "Two nodes share an IP address."
  }

  validation {
    condition     = length(distinct([for n in values(var.talos_nodes) : n.vmid])) == length(var.talos_nodes)
    error_message = "Two nodes share a vmid."
  }

  validation {
    condition     = alltrue([for n in values(var.talos_nodes) : n.memory >= 2048])
    error_message = "memory must be at least 2048 MiB, Talos's documented minimum."
  }
}
