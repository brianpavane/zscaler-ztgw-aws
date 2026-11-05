# Phase 2 - Zero Trust Gateway
#
# Copy to env/<env>.tfvars (e.g. env/prod.tfvars) -- the env name must match
# config/<env>.env. Real *.tfvars files are git-ignored; this file is not.

region = "us-west-2"

# AZ IDs, not AZ names. Phase 3 endpoints can only be placed in these AZs.
availability_zone_ids = ["usw2-az1", "usw2-az2", "usw2-az3"]

# Defaults: gateway_name = ztgw-<env>-<region>, location_name = <gateway_name>-loc
# gateway_name  = "ztgw-prod-us-west-2"
# location_name = "ztgw-prod-us-west-2-loc"

# Account group allowed on the gateway. Phase 3 outputs
# public_cloud_account_id for each onboarded account; list them here.
create_account_group     = true
account_group_member_ids = []

# AWS account IDs allowed WITHOUT Phase 3 onboarding (normally leave empty):
additional_aws_accounts = []
# additional_aws_accounts = ["123456789012"]

cleanup_location_on_destroy = true
