output "kubeconfig" {
  description = "Cluster kubeconfig. Fetch: terraform output -raw kubeconfig > ~/.kube/talos-prod"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "talosctl client config. Fetch: terraform output -raw talosconfig > ~/.talos/config"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "node_ips" {
  description = "Node name to static address"
  value       = { for k, n in var.talos_nodes : k => n.ip }
}

output "controlplane_ip" {
  description = "The control plane's address, which is the cluster endpoint"
  value       = local.controlplane_ip
}
