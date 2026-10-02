locals {
  controlplane_key = one([for k, n in var.talos_nodes : k if n.role == "controlplane"])
  controlplane_ip  = var.talos_nodes[local.controlplane_key].ip

  # No VIP: with one control plane the endpoint is that node.
  cluster_endpoint = "https://${local.controlplane_ip}:6443"

  # The factory installer keeps the qemu-guest-agent extension across
  # upgrades. /dev/sda is scsi0 on virtio-scsi-single.
  install_image = "factory.talos.dev/nocloud-installer/${var.talos_schematic_id}:${var.talos_version}"
}

# The cluster's PKI. It exists only in terraform.tfstate.
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "node" {
  for_each = var.talos_nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = each.value.role
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  # Talos 1.14 replaced machine.install with the UnattendedInstallConfig
  # document, which the provider already generates, with the vanilla
  # installer; a config carrying both is rejected. Patch the document, and
  # name the disk, because patching it drops the generated selector.
  config_patches = [
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UnattendedInstallConfig"
      installer = {
        image = local.install_image
      }
      provisioning = {
        diskSelector = {
          match = "disk.dev_path == \"/dev/sda\""
        }
        wipe = false
      }
    }),
  ]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [local.controlplane_ip]
  nodes                = [for n in values(var.talos_nodes) : n.ip]
}

resource "talos_machine_configuration_apply" "node" {
  for_each = var.talos_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.node[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip

  depends_on = [module.node]
}

resource "talos_machine_bootstrap" "this" {
  node                 = local.controlplane_ip
  endpoint             = local.controlplane_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_configuration_apply.node]
}

resource "talos_cluster_kubeconfig" "this" {
  node                 = local.controlplane_ip
  endpoint             = local.controlplane_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_bootstrap.this]
}
