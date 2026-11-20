locals {
  all_vms = merge(module.vm_server, module.vm_agent)
}

output "vms" {
  description = "Slug of every VM created."
  value       = { for k, v in local.all_vms : k => v.slug }
}

output "public_ips" {
  description = "Public IP of every VM."
  value       = { for k, v in local.all_vms : k => v.public_ip }
}

output "shared_network" {
  description = "Network slug that the agents joined (read from the server)."
  value       = local.server_network
}
