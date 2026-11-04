terraform {
  required_version = ">= 1.7.0"

  required_providers {
    zia = {
      source  = "zscaler/zia"
      version = "~> 4.8"
    }
  }
}
