variable "name" {
  description = "VM name (also used as hostname)."
  type        = string
}

variable "project" {
  type = string
}

variable "region" {
  type = string
}

variable "template" {
  description = "OS template slug."
  type        = string
}

variable "plan" {
  description = "Plan slug (CPU / RAM / disk)."
  type        = string
}

variable "ssh_public_key" {
  description = "Public key installed for the default user on first boot (cloud-init)."
  type        = string
}

variable "network" {
  description = "Slug of an existing private network to join. Empty = the platform creates a new network for this VM."
  type        = string
  default     = ""
}

variable "require_network" {
  description = "Fail instead of silently creating a separate network when 'network' is empty. Set to true for VMs that must share the server's network."
  type        = bool
  default     = false
}
