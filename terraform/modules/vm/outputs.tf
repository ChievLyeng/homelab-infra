output "slug" {
  description = "VM slug (its ID in the GCX API)."
  value       = restapi_object.vm.id
}

output "public_ip" {
  description = "Public IP, read from the last API response (empty until the VM has one; run apply/plan again to refresh)."
  value       = try(jsondecode(restapi_object.vm.api_response).data.ipaddresses[0].name, "")
}
