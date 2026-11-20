variable "gcx_api_url" {
  description = "Base URL of the GCX KCloud API (not secret)."
  type        = string
  default     = "https://api.kcloud.gcx.com.kh/api"
}

variable "gcx_api_token" {
  description = "GCX API token. Set it with TF_VAR_gcx_api_token (the Makefile reads ~/.gcx_token). Never put it in a .tf file."
  type        = string
  sensitive   = true
}

variable "project" {
  description = "GCX project slug."
  type        = string
  default     = "my-project"
}

variable "region" {
  description = "GCX region slug."
  type        = string
  default     = "zone"
}

variable "template" {
  description = "OS template slug."
  type        = string
  default     = "ubuntu-2404-lts-new"
}

variable "plan" {
  description = "VM plan slug (1 vCPU / 1 GB RAM / 35 GB NVMe)."
  type        = string
  default     = "basic-1c-1g-35gb"
}

variable "ssh_public_key_path" {
  description = "Public key that will be installed on the VMs."
  type        = string
  default     = "~/.ssh/homelab.pub"
}

variable "ansible_user" {
  description = "User Ansible logs in as. Starts as the template default 'ubuntu'; switch to the admin user (devops) after the common role has created it."
  type        = string
  default     = "ubuntu"
}
