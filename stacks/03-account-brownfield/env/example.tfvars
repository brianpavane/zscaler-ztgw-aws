# Copy to env/<env>-<instance>.tfvars (one file per AWS account, git-ignored)
# and list <stack>@<instance> in config/<env>.deploy WORKLOADS.
#
# region, endpoint_service_name, availability_zone_ids and
# ztgw_account_group_id come from the gateway automatically
# (env/<env>.wiring.tfvars.json, written by scripts/deploy.sh). Set them here
# only to override, e.g. a subset of the gateway's AZs.

aws_account_id = "111122223333"

# Assume-role mode (omit both for direct mode):
# aws_assume_role_arn         = "arn:aws:iam::111122223333:role/ZscalerAutomation"
# aws_assume_role_external_id = "my-external-id"

# Optional: forward discovery events to Zscaler's event bus (EventBridge).
# enable_event_forwarding = true

# Overrides (normally from the gateway wiring):
# availability_zone_ids = ["usw2-az1", "usw2-az2"]

vpc_id = "vpc-0a1b2c3d4e5f60718"

# One route table per AZ; its 0.0.0.0/0 route moves to that AZ's endpoint.
route_table_ids = {
  "usw2-az1" = "rtb-0a1b2c3d4e5f60711"
  "usw2-az2" = "rtb-0a1b2c3d4e5f60712"
  "usw2-az3" = "rtb-0a1b2c3d4e5f60713"
}

# New /28 endpoint subnets from free space in the VPC (or endpoint_subnet_ids).
endpoint_subnet_cidrs = {
  "usw2-az1" = "10.0.255.0/28"
  "usw2-az2" = "10.0.255.16/28"
  "usw2-az3" = "10.0.255.32/28"
}

# Set to false and apply to roll the default routes back (endpoints stay).
cutover = true
