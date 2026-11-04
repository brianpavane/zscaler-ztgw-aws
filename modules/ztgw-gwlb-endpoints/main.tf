# One Gateway Load Balancer endpoint per AZ, connected to the Zero Trust
# Gateway's endpoint service. Traffic routed to an endpoint is sent through
# the gateway (Zscaler) and returns the same way.

resource "aws_vpc_endpoint" "this" {
  for_each = var.subnet_ids

  vpc_id            = var.vpc_id
  service_name      = var.endpoint_service_name
  vpc_endpoint_type = "GatewayLoadBalancer"
  subnet_ids        = [each.value]

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })
}
