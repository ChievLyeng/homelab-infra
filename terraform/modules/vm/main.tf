resource "restapi_object" "vm" {
  path = "/virtual-machines"

  data = jsonencode({
    name           = var.name
    hostname       = var.name
    cloud_provider = "nimbo"
    project        = var.project
    region         = var.region

    boot_source      = "image"
    server           = "cloud-compute"
    template         = var.template
    template_type    = "Operating System"
    os_family        = "Linux"
    plan             = var.plan
    compute_category = "shared-cpu"
    storage_category = "nvme"
    billing_cycle    = "hourly"

    is_public    = true
    network_type = "Isolated"
    network_plan = "default-isolated" # from GET /plans/service/Network
    # Join an existing private network when one is given.
    networks        = var.network == "" ? [] : [var.network]
    default_network = var.network

    # The account-level SSH key endpoint returns HTTP 500, so the key is
    # installed with cloud-init on first boot instead.
    is_vm_ssh_required      = false
    is_vm_password_required = false
    user_data               = "#cloud-config\nssh_authorized_keys:\n  - ${var.ssh_public_key}\n"

    addons             = []
    additional_options = []
  })

  id_attribute = "data/slug"
  read_path    = "/virtual-machines/{id}"

  # GCX has no DELETE for VMs: a VM is removed with an "Immediate" cancel request.
  destroy_method = "POST"
  destroy_path   = "/billing/service-cancel-requests/{id}"
  destroy_data = jsonencode({
    service_name = "Virtual Machine"
    reason       = "not_needed_anymore"
    type         = "Immediate"
    # Required by the API when the VM has a public IP (not in the published spec).
    delete_public_ip = true
  })

  lifecycle {
    precondition {
      condition     = !var.require_network || var.network != ""
      error_message = "This VM must join the server's network, but no network slug was found. Check that the server VM finished starting."
    }
  }
}
