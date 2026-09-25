# A copy of modules/ubuntu-vm with one data disk for Vault's Raft store.
# Unlike modules/nfs-server this VM is created by Terraform rather than
# imported, so the hard-coded settings need not match an existing machine --
# but they are kept identical to ubuntu-vm anyway, so the three VM modules
# stay comparable.
resource "proxmox_vm_qemu" "vault_vm" {
  name        = var.vm_name
  target_node = var.target_node
  vmid        = var.vmid
  pool        = var.pool
  power_state = "running"

  # A change that needs a reboot must never bounce the root of trust
  # unattended; it is left pending instead.
  automatic_reboot = false

  lifecycle {
    ignore_changes = [
      power_state,
      # clone/full_clone are not strictly needed on a created VM, but they
      # cost nothing and make a later adoption safe: a clone mismatch plans
      # a replacement, which destroys the OS disk.
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

  # Disk configuration. scsi1 appears in the guest as
  # /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1; the vault Ansible
  # role finds it by that name.
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
      # /var/lib/vault. Raft keeps Vault's state here; an audit log that
      # cannot be written stops Vault answering requests, so this disk's
      # free space is operationally load-bearing.
      scsi1 {
        disk {
          size       = var.vault_data_disk_size
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
