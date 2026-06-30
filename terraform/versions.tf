terraform {
  required_version = ">= 1.6.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 7.0.0, < 8.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
    }
  }
}
