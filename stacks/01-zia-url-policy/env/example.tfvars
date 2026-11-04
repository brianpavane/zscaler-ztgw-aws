# Phase 1 - ZIA URL filtering policy
#
# Copy to env/<env>.tfvars (e.g. env/zs2.tfvars) -- the env name must match
# config/<env>.env. Real *.tfvars files are git-ignored; this file is not.

name_prefix = "ztgw-prod"

# ".example.com" = example.com + all subdomains, "example.com" = exact host.
allowed_urls = [
  ".github.com",
  ".amazonaws.com",
]

blocked_urls = [
  ".example-bad-site.com",
]

# ALLOW: unmatched traffic falls through to the rest of the tenant policy.
# BLOCK: unmatched traffic from the scoped locations is blocked.
default_action = "BLOCK"

# Scope. With scripts/deploy.sh, leave location_names unset: the gateway's
# location is supplied automatically (env/<env>.wiring.tfvars.json).
# Without the gateway location the policy is staged (rules DISABLED).
# Set these only to override or add locations.
# location_names = ["ztgw-zs2-us-west-2-loc"]
location_ids = []

rule_order_start = 1
