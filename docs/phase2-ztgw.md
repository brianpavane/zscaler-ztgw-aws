# Phase 2: Zero Trust Gateway (AWS)

Stack: [`stacks/02-ztgw`](../stacks/02-ztgw) · Client:
[`scripts/ztgw/ztgw.py`](../scripts/ztgw/ztgw.py)

## What it creates

| Object | How | Name (defaults) |
|---|---|---|
| Location template | `ztc_location_template` | `<gateway>-tmpl` |
| Consumer account group | `ztc_account_groups` | `<gateway>-consumers` |
| Zero Trust Gateway | `ztgw.py create` / `delete` | `ztgw-<env>-<region>` |
| Gateway location (made by the gateway) | created by Zscaler; deleted by `ztgw.py` on destroy | `<gateway>-loc` |

`<env>` is the Terraform workspace, which `scripts/run.sh` sets to the env
name (`zs2`, `zs3`). So the default gateway names are `ztgw-zs2-us-west-2`
and `ztgw-zs3-us-west-2`.

## Why there is a Python client

`zscaler/ztc` 0.2.0 has no Zero Trust Gateway resource, and the official Go
SDK has no gateway service either. The Cloud & Branch Connector API documents
the gateway endpoints (`/ztGateway`, Zscaler Automation Hub). The client calls
only those, plus location delete and activation:

| Call | Used for |
|---|---|
| `GET /ztGateway?platform=AWS&search=` | find by name (idempotency) |
| `GET /ztGateway/supportedRegions` | refuse unsupported regions before creating |
| `POST /ztGateway` | create |
| `GET /ztGateway/{id}` | health polling, read-back |
| `PUT /ztGateway/{id}` | update account groups / allowed accounts / additional AWS accounts |
| `DELETE /ztGateway/{id}` | delete |
| `GET /location`, `DELETE /location/{id}` | remove the location a deleted gateway leaves behind |
| `PUT /ecAdminActivateStatus/activate` | activate after every change |

| | OneAPI | Legacy |
|---|---|---|
| Base URL | `https://api.zsapi.net/ztw/api/v1` | `https://connector.<cloud>.net/api/v1` |
| Auth | OAuth2 client credentials, `https://<vanity>.zslogin.net/oauth2/v1/token`, audience `https://api.zscaler.com` | `POST /auth` with obfuscated API key, `JSESSIONID` cookie, logout on exit |

The client is Python standard library only and runs as `python3 -I`. TLS is
always verified and non-HTTPS URLs are refused. It retries 429/5xx with
backoff and re-authenticates once on 401. Credentials are read once from the
environment and never logged. OneAPI private-key (JWT) auth is not supported
by the client; use a client secret.

## Lifecycle

| Change | Effect |
|---|---|
| First apply | Template + group created → gateway created (or an existing gateway with the same name **in the same region** is adopted) → wait until `HEALTHY` (default up to 30 min) → activate → read back endpoint service name and location ID |
| `account_group_ids`, `allowed_account_ids`, `additional_aws_accounts` | Gateway updated in place (`PUT`), then activated. |
| `account_group_member_ids` | Applied only when the group is created. After that, Phase 3 manages membership (each Phase 3 stack adds its account on apply and removes it on destroy), so re-applying Phase 2 never drops accounts. |
| `gateway_name`, `region`, `availability_zone_ids`, `location_name`, template | Gateway **replaced** (delete, then create) |
| Destroy | Gateway deleted → wait until gone → leftover location deleted (`cleanup_location_on_destroy`) → activate. Then the template and group are deleted, and `run.sh` activates again. |

Re-running apply after a timeout is safe, because create adopts the gateway
it already started. Every plan reads the gateway live, so a gateway that is
not `HEALTHY` shows up as a `gateway_ready` warning.

## Inputs (`env/<env>.tfvars`)

| Variable | Default | Description |
|---|---|---|
| `region` | `us-west-2` | AWS region |
| `availability_zone_ids` | `["usw2-az1","usw2-az2","usw2-az3"]` | AZ **IDs** (not names) |
| `gateway_name` | `ztgw-<env>-<region>` | |
| `location_name` | `<gateway_name>-loc` | Must be unique in the tenant |
| `existing_location_template_name` | `null` | Use an existing template instead of creating one |
| `location_template` | firewall + IPS on | Settings for the created template |
| `create_account_group` | `true` | Create `<gateway>-consumers` and allow it on the gateway |
| `account_group_member_ids` | `[]` | Initial group members (creation only); Phase 3 manages membership afterwards |
| `account_group_ids` | `[]` | Extra existing groups to allow |
| `allowed_account_ids` | `[]` | Public-cloud-account IDs allowed directly |
| `additional_aws_accounts` | `[]` | Raw AWS account IDs allowed without WDS onboarding |
| `health_timeout_seconds` | `1800` | 60-7200 |
| `cleanup_location_on_destroy` | `true` | |
| `python` | `python3` | Interpreter for the client |

## Outputs

`gateway_name`, `gateway_id`, `region`, `availability_zone_ids`,
`health_status`, `endpoint_service_name` (input to Phase 3), `location_name`
(input to Phase 1), `location_id`, `account_group_id` (input to Phase 3),
`account_group_name`.

## Connecting the phases

```bash
scripts/run.sh zs2 02-ztgw apply
scripts/run.sh zs2 02-ztgw output location_name
# → put it in stacks/01-zia-url-policy/env/zs2.tfvars:
#     location_names = ["ztgw-zs2-us-west-2-loc"]
scripts/run.sh zs2 01-zia-url-policy apply   # policy now ENABLED for the gateway
```

Use `location_names` rather than `location_id` in Phase 1. ZIA looks the
location up by name, which avoids assuming that the Cloud & Branch Connector
location ID equals the ZIA location ID. Confirming that is a live-runbook
item.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Cannot create Zero Trust Gateway while there are pending activation changes` | Another change in the tenant is waiting for activation. Review it, then `python3 -I scripts/ztgw/ztgw.py activate` (with the env exported) or activate in the portal. Activation is tenant-wide, so the client never does this on its own before a create. |
| `Mentioned location name already exists` | A location with that name is left over. Delete it, or set a different `location_name`. Destroys by this stack clean it up automatically. |
| `region ... is not supported` | Run `ztgw.py regions` to list the regions the tenant supports. |
| `not HEALTHY after Ns` | Provisioning is still running. Wait, then re-run apply; it adopts the existing gateway. |
| A gateway with the same name exists in another region | The client refuses to adopt it. Rename one of them. |
