terraform {
  required_version = ">= 1.6"

  required_providers {
    # GCX has no dedicated Terraform provider, so we drive its REST API
    # with the generic restapi provider.
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 1.20"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
