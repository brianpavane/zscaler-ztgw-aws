# Zscaler credentials come from the environment (scripts/run.sh).
provider "ztc" {}

# AWS: two modes, chosen by aws_assume_role_arn.
#   direct      - credentials (AWS_PROFILE) are for the customer account itself
#   assume role - credentials are for a central account; Terraform assumes
#                 aws_assume_role_arn in the customer account
# In both modes allowed_account_ids makes every plan/apply fail if the
# effective credentials are for any other account.
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]

  dynamic "assume_role" {
    for_each = var.aws_assume_role_arn == null ? [] : [var.aws_assume_role_arn]
    content {
      role_arn     = assume_role.value
      external_id  = var.aws_assume_role_external_id
      session_name = "zscaler-ztgw-${terraform.workspace}"
    }
  }

  default_tags {
    tags = merge({ ManagedBy = "terraform", Project = "zscaler-ztgw-aws", Environment = terraform.workspace }, var.tags)
  }
}
