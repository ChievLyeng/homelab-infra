locals {
  # One entry per VM. The "server" is the Kubernetes control plane,
  # the "agents" are the workers that join it.
  vms = {
    "k3s-01" = { role = "server" }
    "k3s-02" = { role = "agent" }
    "k3s-03" = { role = "agent" }
  }

  servers = { for k, v in local.vms : k => v if v.role == "server" }
  agents  = { for k, v in local.vms : k => v if v.role == "agent" }

  # The cluster has exactly one server; its network is the one everyone shares.
  server_name = keys(local.servers)[0]

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

# Step 1: the server. The platform creates a private network for it.
module "vm_server" {
  source   = "../../modules/vm"
  for_each = local.servers

  name           = each.key
  project        = var.project
  region         = var.region
  template       = var.template
  plan           = var.plan
  ssh_public_key = local.ssh_public_key
}

# Step 2: give the server time to finish booting, then read which network it is on.
resource "time_sleep" "server_ready" {
  create_duration = "60s"
  depends_on      = [module.vm_server]
}

data "restapi_object" "server_vm" {
  path         = "/virtual-machines"
  search_key   = "name"
  search_value = local.server_name
  results_key  = "data"
  id_attribute = "slug"

  depends_on = [time_sleep.server_ready]
}

locals {
  # The API wraps the VM in a "data" key: {"status": ..., "data": {..., "networks": [...]}}
  server_network = try(jsondecode(data.restapi_object.server_vm.api_response).data.networks[0].slug, "")
}

# Step 3: the agents join the server's network, so the nodes can talk privately.
module "vm_agent" {
  source   = "../../modules/vm"
  for_each = local.agents

  name            = each.key
  project         = var.project
  region          = var.region
  template        = var.template
  plan            = var.plan
  ssh_public_key  = local.ssh_public_key
  network         = local.server_network
  require_network = true
}

# Terraform writes the Ansible inventory, so the two tools never drift apart.
# The k3s server (control plane) and agents (workers) become Ansible groups.
resource "local_file" "inventory" {
  filename        = "${path.module}/../../../ansible/inventories/prod/hosts.yml"
  file_permission = "0644"

  content = templatefile("${path.module}/inventory.tftpl", {
    ansible_user   = var.ansible_user
    ssh_public_key = local.ssh_public_key
    servers        = { for k, m in module.vm_server : k => m.public_ip }
    agents         = { for k, m in module.vm_agent : k => m.public_ip }
  })
}
