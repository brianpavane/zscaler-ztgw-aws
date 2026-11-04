terraform {
  required_version = ">= 1.7.0"

  required_providers {
    ztc = {
      source  = "zscaler/ztc"
      version = "~> 0.2"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
