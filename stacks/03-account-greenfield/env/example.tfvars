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

vpc_cidr               = "10.20.0.0/16"
private_subnet_newbits = 8
