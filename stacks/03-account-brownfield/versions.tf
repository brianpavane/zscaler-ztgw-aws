terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    ztc = {
      source  = "zscaler/ztc"
      version = "~> 0.2"
    }
  }
}
