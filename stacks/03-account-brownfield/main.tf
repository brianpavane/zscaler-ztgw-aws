# -----------------------------------------------------------------------------
# Phase 3 (brownfield): onboard the account (onboarding.tf), add ZTGW
# endpoints to an existing VPC and move each AZ's default route to them.
#
# Route takeover (no gap in routing):
#   1. The existing 0.0.0.0/0 route of each route table is imported.
#   2. Its target is recorded once in terraform_data.original_route.
#   3. The route is updated in place (EC2 ReplaceRoute) to the endpoint.
# Rollback: cutover = false points the routes back at the recorded targets.
# Destroy (scripts/run.sh): rollback, release the routes from state, then
# destroy the rest, so the original routes stay.
# -----------------------------------------------------------------------------

locals {
  azs = toset(var.availability_zone_ids)

  managed_route_tables = var.release_routes ? {} : var.route_table_ids

  # Subnets explicitly associated with each private route table.
  associated_subnets = {
    for az, rt in data.aws_route_table.private :
    az => [for a in rt.associations : a.subnet_id if a.subnet_id != null && a.subnet_id != ""]
  }
  associated_subnet_azs = {
    for az, ids in local.associated_subnets :
    az => distinct([for id in ids : data.aws_subnet.associated[id].availability_zone_id])
  }
  private_subnet_ids = toset(flatten(values(local.associated_subnets)))

  vpc_cidrs = distinct(concat([data.aws_vpc.this.cidr_block], [for a in data.aws_vpc.this.cidr_block_associations : a.cidr_block]))

  use_new_endpoint_subnets = length(var.endpoint_subnet_cidrs) > 0
  endpoint_subnet_ids      = local.use_new_endpoint_subnets ? { for az, s in aws_subnet.endpoint : az => s.id } : var.endpoint_subnet_ids

  route_target_keys = ["gateway_id", "nat_gateway_id", "transit_gateway_id", "network_interface_id", "vpc_peering_connection_id", "carrier_gateway_id", "local_gateway_id", "core_network_arn"]
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

data "aws_route_table" "private" {
  for_each       = var.route_table_ids
  route_table_id = each.value
}

data "aws_subnet" "associated" {
  for_each = toset(flatten([for rt in data.aws_route_table.private : [for a in rt.associations : a.subnet_id if a.subnet_id != null && a.subnet_id != ""]]))
  id       = each.value
}

data "aws_subnet" "endpoint_existing" {
  for_each = var.endpoint_subnet_ids
  id       = each.value
}

data "aws_route" "current" {
  for_each               = var.route_table_ids
  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
}

# ---- Input checks (fail the plan before anything changes) -------------------

resource "terraform_data" "layout_checks" {
  input = var.route_table_ids

  lifecycle {
    precondition {
      condition     = toset(keys(var.route_table_ids)) == local.azs
      error_message = "route_table_ids keys must be exactly availability_zone_ids."
    }
    precondition {
      condition     = (length(var.endpoint_subnet_cidrs) > 0) != (length(var.endpoint_subnet_ids) > 0)
      error_message = "Set exactly one of endpoint_subnet_cidrs or endpoint_subnet_ids."
    }
    precondition {
      condition     = toset(keys(merge(var.endpoint_subnet_cidrs, var.endpoint_subnet_ids))) == local.azs
      error_message = "endpoint subnet keys must be exactly availability_zone_ids."
    }
    precondition {
      condition     = alltrue([for rt in data.aws_route_table.private : rt.vpc_id == var.vpc_id])
      error_message = "Every route table in route_table_ids must belong to vpc_id."
    }
    precondition {
      condition     = alltrue([for rt in data.aws_route_table.private : !anytrue([for a in rt.associations : a.main])])
      error_message = "A route table in route_table_ids is the VPC main route table; it serves every unassociated subnet in all AZs. Give each AZ its own route table first."
    }
    precondition {
      condition     = alltrue([for az, ids in local.associated_subnets : length(ids) > 0])
      error_message = "A route table in route_table_ids has no subnet associations."
    }
    precondition {
      condition     = alltrue([for az, zones in local.associated_subnet_azs : length(zones) == 1 && contains(zones, az)])
      error_message = "Each route table may only serve subnets in its own AZ (one route table per AZ). Offending: ${jsonencode({ for az, zones in local.associated_subnet_azs : az => zones if !(length(zones) == 1 && contains(zones, az)) })}"
    }
    precondition {
      condition     = alltrue([for az, s in data.aws_subnet.endpoint_existing : s.vpc_id == var.vpc_id && s.availability_zone_id == az && !contains(local.private_subnet_ids, s.id)])
      error_message = "endpoint_subnet_ids must be in vpc_id and the matching AZ, and must not use one of route_table_ids (traffic would loop)."
    }
    precondition {
      condition = alltrue([
        for c in values(var.endpoint_subnet_cidrs) : cidrsubnet(c, 0, 0) == c && anytrue([
          for b in local.vpc_cidrs :
          tonumber(split("/", c)[1]) >= tonumber(split("/", b)[1]) &&
          cidrsubnet("${cidrhost(c, 0)}/${split("/", b)[1]}", 0, 0) == cidrsubnet(b, 0, 0)
        ])
      ])
      error_message = "endpoint_subnet_cidrs must be network addresses (e.g. 10.0.255.0/28) inside the VPC's CIDR blocks ${jsonencode(local.vpc_cidrs)}."
    }
  }
}

# ---- Endpoint subnets ---------------------------------------------------------

resource "aws_subnet" "endpoint" {
  for_each = var.endpoint_subnet_cidrs

  vpc_id               = var.vpc_id
  availability_zone_id = each.key
  cidr_block           = each.value

  tags = { Name = "${local.name}-ztgw-endpoint-${each.key}", Tier = "ztgw-endpoint" }

  depends_on = [terraform_data.layout_checks]
}

# Dedicated table (local route only) so endpoint subnets never use the main
# table, which may itself default-route to an endpoint.
resource "aws_route_table" "endpoint" {
  count  = local.use_new_endpoint_subnets ? 1 : 0
  vpc_id = var.vpc_id
  tags   = { Name = "${local.name}-ztgw-endpoint" }
}

resource "aws_route_table_association" "endpoint" {
  for_each = aws_subnet.endpoint

  subnet_id      = each.value.id
  route_table_id = aws_route_table.endpoint[0].id
}

module "endpoints" {
  source = "../../modules/ztgw-gwlb-endpoints"

  name                  = "${local.name}-ztgw"
  vpc_id                = var.vpc_id
  endpoint_service_name = var.endpoint_service_name
  subnet_ids            = local.endpoint_subnet_ids

  # The account must be allowed on the gateway before endpoints are created.
  depends_on = [module.onboarding, terraform_data.layout_checks]
}

# ---- Default route takeover ---------------------------------------------------

# Original targets, recorded on first apply and never refreshed.
resource "terraform_data" "original_route" {
  for_each = var.route_table_ids

  input = { for k in local.route_target_keys : k => try(data.aws_route.current[each.key][k], null) == null ? "" : data.aws_route.current[each.key][k] }

  lifecycle {
    ignore_changes = [input]

    precondition {
      # On first capture the route must not already point at an endpoint
      # (that would mean the original target is unknown, e.g. lost state).
      # Later plans see our own endpoint, which is fine.
      condition     = !startswith(coalesce(data.aws_route.current[each.key].gateway_id, "-"), "vpce-") || contains(values(module.endpoints.endpoint_ids), data.aws_route.current[each.key].gateway_id)
      error_message = "The default route of ${each.value} already targets endpoint ${coalesce(data.aws_route.current[each.key].gateway_id, "-")}, which is not managed here; its original target is unknown. Restore it manually first."
    }
  }
}

import {
  for_each = var.import_existing_routes ? local.managed_route_tables : {}
  to       = aws_route.default[each.key]
  id       = "${each.value}_0.0.0.0/0"
}

resource "aws_route" "default" {
  #checkov:skip=CKV2_AWS_44:restores the customer's pre-existing default route on rollback; the target is theirs, not chosen here
  for_each = local.managed_route_tables

  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"

  # cutover: the AZ's endpoint. rollback: the recorded original target.
  # GWLB endpoint targets are reported as gateway_id "vpce-..." by EC2.
  vpc_endpoint_id = var.cutover ? module.endpoints.endpoint_ids[each.key] : (
    startswith(terraform_data.original_route[each.key].output.gateway_id, "vpce-") ? terraform_data.original_route[each.key].output.gateway_id : null
  )
  gateway_id = var.cutover || startswith(terraform_data.original_route[each.key].output.gateway_id, "vpce-") ? null : (
    terraform_data.original_route[each.key].output.gateway_id == "" ? null : terraform_data.original_route[each.key].output.gateway_id
  )
  nat_gateway_id            = var.cutover || terraform_data.original_route[each.key].output.nat_gateway_id == "" ? null : terraform_data.original_route[each.key].output.nat_gateway_id
  transit_gateway_id        = var.cutover || terraform_data.original_route[each.key].output.transit_gateway_id == "" ? null : terraform_data.original_route[each.key].output.transit_gateway_id
  network_interface_id      = var.cutover || terraform_data.original_route[each.key].output.network_interface_id == "" ? null : terraform_data.original_route[each.key].output.network_interface_id
  vpc_peering_connection_id = var.cutover || terraform_data.original_route[each.key].output.vpc_peering_connection_id == "" ? null : terraform_data.original_route[each.key].output.vpc_peering_connection_id
  carrier_gateway_id        = var.cutover || terraform_data.original_route[each.key].output.carrier_gateway_id == "" ? null : terraform_data.original_route[each.key].output.carrier_gateway_id
  local_gateway_id          = var.cutover || terraform_data.original_route[each.key].output.local_gateway_id == "" ? null : terraform_data.original_route[each.key].output.local_gateway_id
  core_network_arn          = var.cutover || terraform_data.original_route[each.key].output.core_network_arn == "" ? null : terraform_data.original_route[each.key].output.core_network_arn

  lifecycle {
    precondition {
      condition     = var.cutover || anytrue([for k in local.route_target_keys : terraform_data.original_route[each.key].output[k] != ""])
      error_message = "No original target is recorded for ${each.value}; cannot roll back."
    }
  }
}
