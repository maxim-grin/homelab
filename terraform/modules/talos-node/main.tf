# One Talos node: a full clone of the talos-tp template (the Image Factory
# nocloud image with qemu-guest-agent). Proxmox's cloud-init drive carries the
# static address; Talos's nocloud platform reads it at first boot, so the node
# comes up in maintenance mode on its planned address and the talos provider
# can apply a machine config to it. There is no SSH and no cloud-init user.
resource "proxmox_vm_qemu" "node" {
  name        = var.vm_name
  target_node = var.target_node
  vmid        = var.vmid
  pool        = var.pool
  power_state = "running"

  # A resize needs a restart. Left pending, the operator restarts nodes one
  # at a time; automatic reboots would take all three down together.
  automatic_reboot = false

  lifecycle {
    ignore_changes = [
      power_state,
      clone,
      full_clone,
      # No boot order is set here. Proxmox reports "unset" as -1, and the
      # provider plans to remove that empty block on every run.
      startup_shutdown,
    ]
  }

  clone      = var.clone_template
  full_clone = true

  memory = var.memory
  cpu {
    cores   = var.cpu_cores
    limit   = 0
    numa    = false
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  machine = "q35"
  qemu_os = "l26"
  scsihw  = "virtio-scsi-single"

  boot               = "order=scsi0"
  start_at_node_boot = var.start_at_node_boot

  # The guest agent comes from the image's extension list. In maintenance
  # mode it may not answer yet, so the provider must not wait on it for an
  # SSH address: Talos has no SSH.
  agent                  = 1
  define_connection_info = false
  clone_wait             = 10
  additional_wait        = 5
  skip_ipv6              = true

  disks {
    scsi {
      scsi0 {
        disk {
          size       = var.disk_size
          storage    = var.disk_storage
          format     = "raw"
          iothread   = true
          discard    = true
          cache      = "none"
          backup     = true
          emulatessd = true
          readonly   = false
          replicate  = true
        }
      }
    }
    ide {
      ide2 {
        cloudinit {
          storage = var.cloudinit_storage
        }
      }
    }
  }

  network {
    id        = 0
    model     = "virtio"
    bridge    = var.network_bridge
    firewall  = var.network_firewall
    link_down = false
  }

  serial {
    id   = 0
    type = "socket"
  }

  ipconfig0  = "ip=${var.ip}/${var.prefix_length},gw=${var.gateway}"
  nameserver = var.nameserver

  tags = var.tags
}
