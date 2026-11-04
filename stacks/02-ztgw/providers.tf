# Credentials and the OneAPI/Legacy switch come from environment variables
# exported by scripts/run.sh from config/<env>.env -- never from .tfvars.
#   OneAPI : ZSCALER_CLIENT_ID, ZSCALER_CLIENT_SECRET, ZSCALER_VANITY_DOMAIN,
#            [ZSCALER_CLOUD]
#   Legacy : ZSCALER_USE_LEGACY_CLIENT=true, ZTC_USERNAME, ZTC_PASSWORD,
#            ZTC_API_KEY, ZTC_CLOUD (a production cloud, e.g. zscalertwo)
# scripts/ztgw/ztgw.py reads the same variables.
provider "ztc" {}
