# Credentials and the OneAPI/Legacy switch come from environment variables
# exported by scripts/run.sh from config/<env>.env -- never from .tfvars.
#   OneAPI : ZSCALER_CLIENT_ID, ZSCALER_CLIENT_SECRET | ZSCALER_PRIVATE_KEY,
#            ZSCALER_VANITY_DOMAIN, [ZSCALER_CLOUD]
#   Legacy : ZSCALER_USE_LEGACY_CLIENT=true, ZIA_USERNAME, ZIA_PASSWORD,
#            ZIA_API_KEY, ZIA_CLOUD (e.g. zscalertwo, zscalerthree)
provider "zia" {}
