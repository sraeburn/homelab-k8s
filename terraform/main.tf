terraform {
  required_version = ">= 1.5"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_api_token
  insecure  = var.pve_insecure
  ssh {
    agent    = true
    username = var.pve_ssh_user
  }
}

# "local" storage is per-node, so each node needs its own copy of the image.
moved {
  from = proxmox_virtual_environment_download_file.image
  to   = proxmox_virtual_environment_download_file.image["pve1"]
}

resource "proxmox_virtual_environment_download_file" "image" {
  for_each     = { for n in var.nodes : n.name => n }
  content_type = "iso"
  datastore_id = var.iso_datastore
  node_name    = each.value.name
  url          = var.image_url
  file_name    = "k3s-base-cloudimg.img"
}

resource "proxmox_virtual_environment_vm" "k3s" {
  for_each  = { for n in var.nodes : n.name => n }
  name      = each.value.vm_name
  node_name = each.value.name
  tags      = ["k3s", each.value.role]

  # Ubuntu cloud images ship without qemu-guest-agent; waiting for it hangs apply.
  agent { enabled = false }

  cpu {
    cores = var.vm_cores
    type  = "x86-64-v2-AES"
  }
  memory { dedicated = var.vm_memory_mb }

  disk {
    datastore_id = var.vm_datastore
    file_id      = proxmox_virtual_environment_download_file.image[each.key].id
    interface    = "scsi0"
    size         = var.vm_disk_gb
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge = var.bridge
  }

  initialization {
    datastore_id = var.vm_datastore
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.cidr_prefix}"
        gateway = var.gateway
      }
    }
    dns { servers = var.dns_servers }
    user_account {
      username = var.vm_user
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_file)))]
    }
  }

  operating_system { type = "l26" }
}
