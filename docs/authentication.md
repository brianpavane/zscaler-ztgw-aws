# Authentication

Every stack can use either Zscaler API framework. You pick one per
environment with `ZSCALER_AUTH_MODE` in `config/<env>.env`. `scripts/run.sh`
then exports **only** that framework's variables (and unsets the other
framework's), because the providers read their credentials from the
environment.

## OneAPI (`ZSCALER_AUTH_MODE=oneapi`)

For tenants migrated to ZIdentity.

| Setting | Notes |
|---|---|
| `ZSCALER_CLIENT_ID` | ZIdentity API client ID |
| `ZSCALER_CLIENT_SECRET` | Client secret, **or** use `ZSCALER_PRIVATE_KEY` |
| `ZSCALER_VANITY_DOMAIN` | e.g. `acme` for `acme.zslogin.net` |
| `ZSCALER_CLOUD` | Leave **empty** for production (ZS2/ZS3). Only `beta`, `gov`, `govus` use it. |

Create the API client in ZIdentity (Integration → API Clients) and give it
API roles for:

- **ZIA**: URL Filtering policy, URL categories, location read, activation
  (Phase 1).
- **Cloud & Branch Connector**: ZT Gateway, partner integrations (public cloud
  info, account groups), location templates, activation (Phase 2+).

`run.sh` sets `ZSCALER_USE_LEGACY_CLIENT=false`.

The Zero Trust Gateway client (`scripts/ztgw/ztgw.py`, Phase 2) supports
**client-secret** OneAPI auth only. `run.sh` refuses a private-key-only env
file for stacks that use `ztc`.

## Legacy API (`ZSCALER_AUTH_MODE=legacy`)

For tenants not yet on ZIdentity.

| Setting | Notes |
|---|---|
| `ZIA_USERNAME`, `ZIA_PASSWORD` | ZIA API admin |
| `ZIA_API_KEY` | ZIA Administration → API Key Management |
| `ZIA_CLOUD` | `zscalertwo` (ZS2) or `zscalerthree` (ZS3) |
| `ZTC_USERNAME`, `ZTC_PASSWORD`, `ZTC_API_KEY`, `ZTC_CLOUD` | Cloud & Branch Connector admin + key (Phase 2+) |

`run.sh` sets `ZSCALER_USE_LEGACY_CLIENT=true` and checks the cloud names.
It requires only the credentials of the products a stack uses: `ZIA_*` for
stacks that use the `zia` provider, and `ZTC_*` for stacks that use `ztc`
(Phase 2 needs only `ZTC_*`).

## Safeguards in `run.sh`

- The env file must be mode `600` or `400`.
- The file is **parsed**, not sourced. No shell expansion or command
  substitution, and unknown keys (typos) are rejected.
- The env name and stack name must be `[A-Za-z0-9_-]`, which blocks path
  traversal.
- Missing credentials for the selected mode fail before Terraform runs.
- Credentials are passed to Terraform only through the environment, never as
  arguments. Phase 1 state contains no secrets.

## AWS (Phase 2+)

Use the standard AWS SDK chain. Set `AWS_PROFILE` (SSO or assume-role
profile recommended) in the env file; static keys are not accepted by the
env-file parser on purpose.
