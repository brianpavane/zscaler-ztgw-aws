# Phase 3 (greenfield): onboard the account and build a new VPC whose private
# subnets default-route through the Zero Trust Gateway. See onboarding.tf.

module "vpc" {
  source = "../../modules/ztgw-vpc-greenfield"

  name                   = local.name
  vpc_cidr               = var.vpc_cidr
  private_subnet_newbits = var.private_subnet_newbits
  availability_zone_ids  = var.availability_zone_ids
  endpoint_service_name  = var.endpoint_service_name

  # The account must be allowed on the gateway before endpoints are created.
  depends_on = [module.onboarding]
}
