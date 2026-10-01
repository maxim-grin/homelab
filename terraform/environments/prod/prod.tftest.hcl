# Mock providers: nothing here reaches Proxmox or a Talos node. These tests
# pin the rules the node map must obey.
mock_provider "proxmox" {}
mock_provider "talos" {}

variables {
  pm_api_url          = "https://pve.invalid:8006/api2/json"
  pm_api_token_id     = "terraform@pve!test"
  pm_api_token_secret = "not-a-secret"
  pm_target_node      = "pve"
  gateway             = "10.0.0.1"
  talos_nodes = {
    cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.110", memory = 2048 }
    w1  = { role = "worker", vmid = 3201, ip = "10.0.0.111", memory = 2048 }
    w2  = { role = "worker", vmid = 3202, ip = "10.0.0.112", memory = 2048 }
  }
}

run "three_nodes_one_controlplane" {
  command = plan

  assert {
    condition     = length(output.node_ips) == 3
    error_message = "expected three nodes"
  }
  assert {
    condition     = output.controlplane_ip == "10.0.0.110"
    error_message = "the control plane address must be cp1's"
  }
}

run "rejects_two_controlplanes" {
  command = plan
  variables {
    talos_nodes = {
      cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.110", memory = 2048 }
      cp2 = { role = "controlplane", vmid = 3102, ip = "10.0.0.111", memory = 2048 }
      w1  = { role = "worker", vmid = 3201, ip = "10.0.0.112", memory = 2048 }
    }
  }
  expect_failures = [var.talos_nodes]
}

run "rejects_no_controlplane" {
  command = plan
  variables {
    talos_nodes = {
      w1 = { role = "worker", vmid = 3201, ip = "10.0.0.111", memory = 2048 }
      w2 = { role = "worker", vmid = 3202, ip = "10.0.0.112", memory = 2048 }
    }
  }
  expect_failures = [var.talos_nodes]
}

run "rejects_duplicate_ip" {
  command = plan
  variables {
    talos_nodes = {
      cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.110", memory = 2048 }
      w1  = { role = "worker", vmid = 3201, ip = "10.0.0.110", memory = 2048 }
    }
  }
  expect_failures = [var.talos_nodes]
}

run "rejects_duplicate_vmid" {
  command = plan
  variables {
    talos_nodes = {
      cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.110", memory = 2048 }
      w1  = { role = "worker", vmid = 3101, ip = "10.0.0.111", memory = 2048 }
    }
  }
  expect_failures = [var.talos_nodes]
}

run "rejects_small_memory" {
  command = plan
  variables {
    talos_nodes = {
      cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.110", memory = 1024 }
    }
  }
  expect_failures = [var.talos_nodes]
}

run "rejects_bad_ip" {
  command = plan
  variables {
    talos_nodes = {
      cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.300", memory = 2048 }
    }
  }
  expect_failures = [var.talos_nodes]
}

run "rejects_unknown_role" {
  command = plan
  variables {
    talos_nodes = {
      cp1 = { role = "controlplane", vmid = 3101, ip = "10.0.0.110", memory = 2048 }
      w1  = { role = "master", vmid = 3201, ip = "10.0.0.111", memory = 2048 }
    }
  }
  expect_failures = [var.talos_nodes]
}
