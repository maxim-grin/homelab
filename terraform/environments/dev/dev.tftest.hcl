# Mock provider: nothing here reaches Proxmox. These tests pin the dev
# cluster to exactly the kubeadm-dev nodes: names, vmids, sizes, boot order.
mock_provider "proxmox" {}

variables {
  pm_api_url            = "https://pve.invalid:8006/api2/json"
  pm_api_token_id       = "terraform@pve!test"
  pm_api_token_secret   = "not-a-secret"
  pm_target_node        = "pve"
  ci_user               = "test"
  ci_password           = "<PASSWORD>"
  gateway               = "10.0.0.1"
  project               = "homelab"
  environment           = "dev"
  ssh_private_key_path  = "/dev/null"
  ub_k8s_cidr           = "10.0.0.0/24"
  clone_template_k8s    = "tmpl"
  clone_template_ubuntu = "tmpl"
  claude_code_ip        = "10.0.0.130/24"
}

run "exactly_the_kubeadm_dev_vms" {
  command = plan

  assert {
    condition     = sort([for n in values(output.master_nodes) : n.vm_name]) == ["kubeadm-dev-cp1"]
    error_message = "the only control plane must be kubeadm-dev-cp1"
  }
  assert {
    condition     = sort([for n in values(output.worker_nodes) : n.vm_name]) == ["kubeadm-dev-w1"]
    error_message = "the only worker must be kubeadm-dev-w1"
  }
  assert {
    condition     = sort(values(output.all_node_vmids)) == [4101, 4201]
    error_message = "vmids must be 4101 and 4201 (cluster_id 4)"
  }
}

run "kubeadm_dev_sizes_and_boot" {
  command = plan

  assert {
    condition     = alltrue([for n in concat(values(output.master_nodes), values(output.worker_nodes)) : n.memory == 3072])
    error_message = "both nodes get 3072 MB"
  }
  assert {
    condition     = alltrue([for n in concat(values(output.master_nodes), values(output.worker_nodes)) : n.disk_size == "30G"])
    error_message = "both disks are 30G"
  }
  assert {
    condition     = alltrue([for n in concat(values(output.master_nodes), values(output.worker_nodes)) : n.start_at_node_boot])
    error_message = "both nodes start at node boot"
  }
  assert {
    condition     = values(output.master_nodes)[0].startup == "order=20,up=60" && values(output.worker_nodes)[0].startup == "order=30"
    error_message = "master order=20,up=60 and worker order=30"
  }
}
