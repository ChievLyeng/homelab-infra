provider "restapi" {
  uri = var.gcx_api_url

  headers = {
    Authorization  = "Bearer ${var.gcx_api_token}"
    Accept         = "application/json"
    "Content-Type" = "application/json"
  }

  # GCX wraps every response as {"status": ..., "data": {...}}.
  id_attribute         = "data/slug"
  write_returns_object = true
  timeout              = 60
}
