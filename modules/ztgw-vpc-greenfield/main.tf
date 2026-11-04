# -----------------------------------------------------------------------------
# Greenfield VPC behind the Zero Trust Gateway.
#
# Per AZ:   endpoint subnet (/28) -> GWLB endpoint to the ZTGW
#           private subnet         -> own route table, 0.0.0.0/0 -> that AZ's endpoint
# Shared:   one endpoint route table (local route only, so traffic leaving an
#           endpoint never loops back into it).
#
# No internet or NAT gateway: all egress goes through Zscaler.
#
# Addressing: the VPC is split into private-sized blocks. Block 0 is carved
# into /28 endpoint subnets; blocks 1..n are the private subnets.
# -----------------------------------------------------------------------------

locals {
  azs            = { for i, az in var.availability_zone_ids : az => i }
  endpoint_block = cidrsubnet(var.vpc_cidr, var.private_subnet_newbits, 0)
  vpc_prefix     = tonumber(split("/", var.vpc_cidr)[1])
  # newbits from the endpoint block down to /28
  endpoint_newbits = 28 - (local.vpc_prefix + var.private_subnet_newbits)

  # Computed only when the layout fits; otherwise the preconditions on
  # aws_vpc.this report a readable error instead of a cidrsubnet() failure.
  fits_private   = pow(2, var.private_subnet_newbits) > length(var.availability_zone_ids)
  fits_endpoints = local.endpoint_newbits >= 0 && pow(2, max(local.endpoint_newbits, 0)) >= length(var.availability_zone_ids)
  fits           = local.fits_private && local.fits_endpoints

  private_cidrs  = local.fits ? { for az, i in local.azs : az => cidrsubnet(var.vpc_cidr, var.private_subnet_newbits, i + 1) } : {}
  endpoint_cidrs = local.fits ? { for az, i in local.azs : az => cidrsubnet(local.endpoint_block, local.endpoint_newbits, i) } : {}
}

resource "aws_vpc" "this" {
  #checkov:skip=CKV2_AWS_11:VPC flow logs depend on the customer's logging account and are out of scope for v1
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    precondition {
      condition     = local.fits_endpoints
      error_message = "private subnets are too small to hold the /28 endpoint subnets; lower private_subnet_newbits."
    }
    precondition {
      condition     = local.fits_private
      error_message = "vpc_cidr is too small for one private subnet per AZ plus the endpoint block; raise private_subnet_newbits or use a larger VPC."
    }
  }
}

# Lock down the default security group (no rules).
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-default-deny" })
}

resource "aws_subnet" "endpoint" {
  for_each = local.endpoint_cidrs

  vpc_id               = aws_vpc.this.id
  availability_zone_id = each.key
  cidr_block           = each.value

  tags = merge(var.tags, { Name = "${var.name}-ztgw-endpoint-${each.key}", Tier = "ztgw-endpoint" })
}

resource "aws_subnet" "private" {
  for_each = local.private_cidrs

  vpc_id               = aws_vpc.this.id
  availability_zone_id = each.key
  cidr_block           = each.value

  tags = merge(var.tags, { Name = "${var.name}-private-${each.key}", Tier = "private" })
}

resource "aws_route_table" "endpoint" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-ztgw-endpoint" })
}

resource "aws_route_table_association" "endpoint" {
  for_each = aws_subnet.endpoint

  subnet_id      = each.value.id
  route_table_id = aws_route_table.endpoint.id
}

module "endpoints" {
  source = "../ztgw-gwlb-endpoints"

  name                  = "${var.name}-ztgw"
  vpc_id                = aws_vpc.this.id
  endpoint_service_name = var.endpoint_service_name
  subnet_ids            = { for az, s in aws_subnet.endpoint : az => s.id }
  tags                  = var.tags
}

resource "aws_route_table" "private" {
  for_each = aws_subnet.private

  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-private-${each.key}" })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route" "default_via_ztgw" {
  for_each = aws_route_table.private

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = module.endpoints.endpoint_ids[each.key]
}
