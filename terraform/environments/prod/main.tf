# The Talos prod cluster: one control plane and two workers, cloned from the
# talos-tp template. The node map lives in prod.tfvars.
module "node" {
  source   = "../../modules/talos-node"
  for_each = var.talos_nodes

  vm_name        = "${var.cluster_name}-${each.key}"
  target_node    = var.pm_target_node
  vmid           = each.value.vmid
  pool           = var.pool
  clone_template = var.clone_template

  memory    = each.value.memory
  cpu_cores = var.node_cores
  disk_size = var.node_disk_size

  ip            = each.value.ip
  prefix_length = var.prefix_length
  gateway       = var.gateway
  nameserver    = var.nameserver
}
