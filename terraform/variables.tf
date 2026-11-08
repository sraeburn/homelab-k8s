variable "pve_endpoint" {
  type        = string
  description = "Proxmox API URL, e.g. https://pve1.lan:8006/"
}

variable "pve_api_token" {
  type        = string
  sensitive   = true
  description = "user@realm!tokenid=secret"
}

variable "pve_insecure" {
  type    = bool
  default = true
}

variable "pve_ssh_user" {
  type    = string
  default = "root"
}

variable "nodes" {
  description = "One VM per Proxmox node. Exactly one role = server."
  type = list(object({
    name    = string # Proxmox node name
    vm_name = string
    ip      = string
    role    = string # server | agent
  }))
}

variable "iso_datastore" {
  type    = string
  default = "local"
}

variable "snippets_datastore" {
  type        = string
  default     = "local"
  description = "Storage with the Snippets content type enabled (holds cloud-init vendor data)"
}

variable "vm_datastore" {
  type    = string
  default = "local-lvm"
}

variable "image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "cidr_prefix" {
  type    = number
  default = 24
}

variable "gateway" {
  type = string
}

variable "dns_servers" {
  type    = list(string)
  default = ["1.1.1.1"]
}

variable "vm_user" {
  type    = string
  default = "ubuntu"
}

variable "ssh_public_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "vm_cores" {
  type    = number
  default = 2
}

variable "vm_memory_mb" {
  type    = number
  default = 8192
}

variable "vm_disk_gb" {
  type    = number
  default = 32
}
