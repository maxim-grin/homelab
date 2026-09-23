# A copy of modules/ubuntu-vm with two data disks. nfs-01 was created by
# ubuntu-vm and adopted with an import block, so every hard-coded setting
# below must stay identical to ubuntu-vm's: a difference is drift the next
# plan tries to correct, and some of it forces a replacement.
resource "proxmox_vm_qemu" "nfs_server" {
  name        = var.vm_name
  target_node = var.target_node
  vmid        = var.vmid
  pool        = var.pool
  power_state = "running"

  # Attaching the data disks must not reboot the VM out from under every
  # mounted PVC. A change that needs a reboot is left pending instead.
  automatic_reboot = false

  lifecycle {
    ignore_changes = [
      power_state,
      # An imported VM need not report the template it was cloned from, and
      # a clone mismatch plans a replacement -- which destroys the OS disk.
      clone,
      full_clone,
    ]
  }

  # Clone settings
  clone      = var.clone_template
  full_clone = var.full_clone

  # Resource allocation
  memory = var.memory
  cpu {
    cores   = var.cpu_cores
    limit   = 0
    numa    = false
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  # System settings
  machine = "q35"
  qemu_os = "l26"
  scsihw  = "virtio-scsi-single"

  # Boot and startup
  boot               = "order=scsi0"
  start_at_node_boot = var.start_at_node_boot
  startup            = var.startup

  # Agent and connection settings
  agent                  = 1
  define_connection_info = true
  clone_wait             = 10
  additional_wait        = 5
  agent_timeout          = 300
  skip_ipv6              = true

  # Disk configuration. scsi1 and scsi2 appear in the guest as
  # /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi{1,2}; the
  # nfs_server Ansible role finds them by those names.
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
      scsi1 {
        disk {
          size       = var.nfs_dev_disk_size
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
      scsi2 {
        disk {
          size       = var.nfs_prod_disk_size
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
      ide3 {
        cloudinit {
          storage = var.cloudinit_storage
        }
      }
    }
  }

  # Network configuration
  network {
    id        = 0
    model     = "virtio"
    bridge    = var.network_bridge
    firewall  = var.network_firewall
    link_down = false
  }

  # Serial console
  serial {
    id   = 0
    type = "socket"
  }

  # Cloud-init settings
  ciuser     = var.ci_user
  cipassword = var.ci_password
  sshkeys    = var.ssh_public_key
  ipconfig0  = var.ip_config

  # Tags
  tags = var.tags
}
