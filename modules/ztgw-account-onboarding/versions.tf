terraform {
  required_version = ">= 1.7.0"

  required_providers {
    # Used by the child module ../aws-wds-role. Declared here so callers and
    # tests (mock_provider "aws") configure it for this module.
    # tflint-ignore: terraform_unused_required_providers
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
