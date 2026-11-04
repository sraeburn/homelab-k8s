output "ansible_inventory" {
  description = "Paste into ansible/inventory.ini (or: terraform output -raw ansible_inventory > ../ansible/inventory.ini)"
  value = join("\n", concat(
    ["[server]"],
    [for n in var.nodes : "${n.vm_name} ansible_host=${n.ip}" if n.role == "server"],
    ["", "[agent]"],
    [for n in var.nodes : "${n.vm_name} ansible_host=${n.ip}" if n.role == "agent"],
    ["", "[k3s:children]", "server", "agent", "", "[k3s:vars]", "ansible_user=${var.vm_user}", ""]
  ))
}
