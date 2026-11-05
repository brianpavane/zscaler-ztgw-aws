# Getting started: install, configure, run

This guide takes you from an empty laptop to a working Zero Trust Gateway
(ZTGW) with your AWS accounts behind it. Follow the steps in order. Every
step says **what** to do, **how** to do it, and **how to check** that it
worked.

**What you will end up with:**

```
Your AWS account (VPC)                   Zscaler
┌──────────────────────────┐            ┌───────────────────────────────┐
│ servers ─► GWLB endpoint ─┼──────────► │ Zero Trust Gateway (Phase 2) │
└──────────────────────────┘            │   └► URL policy (Phase 1)    │
   onboarded (Phase 3)                  └───────────────────────────────┘
```

| Phase | What it does | Stack |
|---|---|---|
| 1 | URL filtering policy (allow list, block list, default) | `01-zia-url-policy` |
| 2 | The Zero Trust Gateway in one AWS region | `02-ztgw` |
| 3 | Each AWS account: Zscaler onboarding + a VPC that sends traffic through the gateway | `03-account-greenfield` (new VPC) or `03-account-brownfield` (existing VPC) |

**Time:** about 30 minutes to set up, then up to 30 minutes for Zscaler to
build the gateway the first time.

---

## Step 0. Choose your names

You choose three short names, and the commands in this guide reuse them as
shell variables. Set them once in your terminal, and every command below can
be copied as-is.

```bash
export ZTGW_ENV=prod        # a name for your Zscaler tenant (environment)
export ZTGW_ACCOUNT=app1    # a short name for your first AWS account
export ZTGW_REGION=us-west-2   # the AWS region for the gateway
```

| Variable | What it is | Rules | Examples |
|---|---|---|---|
| `ZTGW_ENV` | One name per Zscaler tenant. It names your config files and the gateway (`ztgw-prod-us-west-2`). It does **not** pick the Zscaler cloud; your credentials do. | letters, digits, `-`, `_` | `prod`, `dev`, `lab` |
| `ZTGW_ACCOUNT` | One name per AWS account you put behind the gateway | letters, digits, `-`, `_` | `app1`, `shared`, `core` |
| `ZTGW_REGION` | AWS region of the gateway. Every AWS account behind it uses the same region. | an AWS region | `us-west-2`, `us-east-1`, `eu-central-1` |

> The tools themselves don't read these variables; they only make the
> commands in this guide copy-and-paste. If you open a new terminal window,
> run the three `export` lines again.

---

## Step 1. Install the tools

You need five things:

| Tool | Version | Why |
|---|---|---|
| Terraform | **1.7 or newer** | builds everything |
| Python 3 | **3.9 or newer** | small Zscaler API client (standard library only, nothing to `pip install`) |
| bash | any (macOS's built-in 3.2 is fine) | runs the scripts |
| git | any | downloads this repository |
| AWS CLI v2 | any | sets up your AWS login (profile) and looks up IDs |

### macOS

1. Install Homebrew, if you don't have it (see https://brew.sh):

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

2. Install the tools:

   ```bash
   brew tap hashicorp/tap
   brew install hashicorp/tap/terraform python git awscli
   ```

   > Use `hashicorp/tap/terraform`, not plain `brew install terraform`.
   > Homebrew's own `terraform` formula stays at **1.5.x**, which is too old.
   > If `terraform version` shows 1.5, switch:
   >
   > ```bash
   > brew uninstall terraform && brew install hashicorp/tap/terraform
   > ```

### Linux (Ubuntu / Debian)

```bash
sudo apt-get update
sudo apt-get install -y gnupg software-properties-common curl unzip git python3

# Terraform (HashiCorp's official package repository)
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# AWS CLI v2
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install
```

### Windows

Use **WSL2** (Windows Subsystem for Linux) with Ubuntu, then follow the
Linux steps inside it. The scripts are bash scripts and don't run in
PowerShell or cmd.

### ✅ Check

```bash
terraform version     # Terraform v1.7.0 or newer
python3 --version     # Python 3.9 or newer
bash --version        # any
git --version         # any
aws --version         # aws-cli/2.x
```

---

## Step 2. Download the code

```bash
git clone https://github.com/brianpavane/zscaler-ztgw-aws.git
cd zscaler-ztgw-aws
```

> **Run every command in this guide from this folder.**

### ✅ Check

```bash
ls scripts/deploy.sh config/example.env   # both files are listed
```

---

## Step 3. Get Zscaler API credentials

Use **one** of the two options. If your tenant logs in through ZIdentity
(`https://<something>.zslogin.net`), use **Option A**.

### Option A: OneAPI (recommended)

1. Sign in to the **ZIdentity Admin Portal**.
2. Go to **Integration → API Clients → Add API Client**.
3. Choose **Client Secret** authentication. (Private-key authentication
   isn't supported for the gateway steps.)
4. Give the client API roles that cover:
   - **ZIA:** URL Filtering policy, URL categories, location (read),
     activation. This is for Phase 1.
   - **Cloud & Branch Connector:** Zero Trust Gateway, Partner Integrations
     (public cloud accounts, account groups, discovery service), location
     templates, activation. This is for Phases 2 and 3.
5. Save, and write down three values:

| You need | Where to find it | Example |
|---|---|---|
| Client ID | shown on the API client | `0oa1b2c3d4e5f6g7h8i9` |
| Client Secret | shown **once** when you create it | `AbCdEf...` |
| Vanity domain | the first part of your login URL `https://acme.zslogin.net` | `acme` |

### Option B: Legacy API

You need an admin account that may use the API, plus an API key, in **both**
admin portals:

| Product | Needed for | Where |
|---|---|---|
| ZIA | Phase 1 | ZIA Admin Portal → Administration → API Key Management |
| Cloud & Branch Connector | Phases 2 and 3 | Cloud & Branch Connector Admin Portal → Administration → API Key Management |

Also write down your **cloud name**: it's in the admin portal address.

| Portal address contains | Cloud name |
|---|---|
| `zscaler.net` | `zscaler` |
| `zscalerone.net` | `zscalerone` |
| `zscalertwo.net` | `zscalertwo` |
| `zscalerthree.net` | `zscalerthree` |
| `zscloud.net` | `zscloud` |

> Never paste these credentials into chat, email, tickets or a git commit.
> They go in **one** file only, in Step 5.

---

## Step 4. Set up AWS access

Terraform signs in to AWS with a **named AWS CLI profile**. Choose one mode
for each AWS account:

| Mode | When to use it | The profile signs in to |
|---|---|---|
| **Direct** | You can sign in to the workload account itself | the workload account |
| **Assume role** | You sign in to a central account and jump into the workload accounts | your central account; a role in each workload account trusts it |

The identity Terraform uses in the workload account needs permission to
create VPC resources (VPC, subnets, route tables, VPC endpoints), IAM roles
with inline policies, and, if you turn on event forwarding, EventBridge
rules.

### Create the profile (AWS IAM Identity Center / SSO, recommended)

```bash
aws configure sso --profile ztgw-prod
# answer the prompts: SSO start URL, SSO region, account, role
aws sso login --profile ztgw-prod
```

### ✅ Check

```bash
aws sts get-caller-identity --profile ztgw-prod
# "Account": "111122223333"  <- the workload account (direct mode)
#                               or your central account (assume-role mode)
```

### Look up your Availability Zone IDs

The gateway uses AZ **IDs** (`usw2-az1`), not AZ names (`us-west-2a`). Names
differ between AWS accounts, but IDs are the same everywhere.

```bash
aws ec2 describe-availability-zones --region "$ZTGW_REGION" --profile ztgw-prod \
  --query 'AvailabilityZones[].[ZoneName,ZoneId]' --output table
```

Pick 2 or 3 of these IDs for the gateway (more AZs means higher
availability).

---

## Step 5. Create the configuration files

Each file below has a commented example in the repo. You **copy the
example**, then **edit the copy**. Your copies are git-ignored, so they can
never be committed by accident.

| # | File (you create it) | Contents |
|---|---|---|
| 5.1 | `config/$ZTGW_ENV.env` | Zscaler credentials + AWS profile (**secret**) |
| 5.2 | `config/$ZTGW_ENV.deploy` | Which phases and which AWS accounts this environment has |
| 5.3 | `stacks/01-zia-url-policy/env/$ZTGW_ENV.tfvars` | URL allow and block lists |
| 5.4 | `stacks/02-ztgw/env/$ZTGW_ENV.tfvars` | Gateway region and AZs |
| 5.5 | `stacks/03-account-greenfield/env/$ZTGW_ENV-$ZTGW_ACCOUNT.tfvars` | One AWS account with a **new** VPC |
| 5.6 | `stacks/03-account-brownfield/env/$ZTGW_ENV-$ZTGW_ACCOUNT.tfvars` | One AWS account with an **existing** VPC (instead of 5.5) |

**File format rules:**
- `.env` and `.deploy` files: one `KEY=value` per line. `#` starts a
  comment. Quotes are optional. No `export`, no `$VARIABLES`.
- `.tfvars` files: Terraform syntax. Text goes in `"quotes"`, lists in
  `[ ]`, maps in `{ }`.

### 5.1 Credentials: `config/$ZTGW_ENV.env`

```bash
cp config/example.env "config/$ZTGW_ENV.env"
chmod 600 "config/$ZTGW_ENV.env"          # required: only you can read it
open -e "config/$ZTGW_ENV.env"            # macOS; or: nano "config/$ZTGW_ENV.env"
```

**Example (Option A, OneAPI).** Fill in your values and leave the Legacy
lines empty:

```bash
ZSCALER_AUTH_MODE=oneapi
ZSCALER_CLIENT_ID=0oa1b2c3d4e5f6g7h8i9
ZSCALER_CLIENT_SECRET=paste-the-client-secret-here
ZSCALER_VANITY_DOMAIN=acme
ZSCALER_CLOUD=                 # leave empty for every production cloud

AWS_PROFILE=ztgw-prod          # the profile from Step 4
AWS_REGION=us-west-2
```

**Example (Option B, Legacy):**

```bash
ZSCALER_AUTH_MODE=legacy
ZIA_USERNAME=api-admin@acme.com
ZIA_PASSWORD=paste-the-password-here
ZIA_API_KEY=paste-the-zia-api-key-here
ZIA_CLOUD=zscalertwo
ZTC_USERNAME=api-admin@acme.com
ZTC_PASSWORD=paste-the-password-here
ZTC_API_KEY=paste-the-connector-api-key-here
ZTC_CLOUD=zscalertwo

AWS_PROFILE=ztgw-prod
AWS_REGION=us-west-2
```

| Key | Required | Meaning |
|---|---|---|
| `ZSCALER_AUTH_MODE` | yes | `oneapi` or `legacy` |
| `ZSCALER_CLIENT_ID`, `ZSCALER_CLIENT_SECRET`, `ZSCALER_VANITY_DOMAIN` | OneAPI | from Step 3, Option A |
| `ZSCALER_CLOUD` | no | leave empty for production clouds |
| `ZIA_*` | Legacy, Phase 1 | from Step 3, Option B |
| `ZTC_*` | Legacy, Phases 2 and 3 | from Step 3, Option B |
| `AWS_PROFILE` | Phase 3 | the profile from Step 4 |
| `AWS_REGION` | no | default region for the AWS CLI tools |

Unknown keys (typos) are rejected, so a mistake is reported instead of
being silently ignored.

#### ✅ Check

```bash
scripts/run.sh "$ZTGW_ENV" 02-ztgw auth-check
# [run] credentials for auth mode 'oneapi' are present
```

This checks that the file is complete and private, and that Terraform is new
enough. It doesn't contact Zscaler; the plan in Step 6 does.

### 5.2 What to deploy: `config/$ZTGW_ENV.deploy`

```bash
cp config/example.deploy "config/$ZTGW_ENV.deploy"
```

**Example:** the URL policy, the gateway, and one AWS account with a new VPC:

```bash
URL_POLICY=true
GATEWAY=true
WORKLOADS="03-account-greenfield@app1"
```

**Example:** two AWS accounts, one new VPC and one existing VPC:

```bash
URL_POLICY=true
GATEWAY=true
WORKLOADS="03-account-greenfield@app1 03-account-brownfield@core"
```

| Key | Values | Meaning |
|---|---|---|
| `URL_POLICY` | `true` / `false` | Phase 1 |
| `GATEWAY` | `true` / `false` | Phase 2 |
| `WORKLOADS` | space-separated `<stack>@<account name>` in quotes | Phase 3. One entry per AWS account. The part after `@` is the account name (`ZTGW_ACCOUNT`), and it picks the tfvars file `env/<env>-<account name>.tfvars`. |

### 5.3 URL policy (Phase 1): `stacks/01-zia-url-policy/env/$ZTGW_ENV.tfvars`

```bash
cp stacks/01-zia-url-policy/env/example.tfvars "stacks/01-zia-url-policy/env/$ZTGW_ENV.tfvars"
```

**Example:**

```hcl
name_prefix = "ztgw-prod"            # prefix for the ZIA rules and categories; unique in the tenant

allowed_urls = [
  ".github.com",                     # leading dot = the domain AND all subdomains
  ".amazonaws.com",
  "api.example.com",                 # no dot = exactly this host
]

blocked_urls = [
  ".example-bad-site.com",
]

default_action = "BLOCK"             # anything not in either list: BLOCK or ALLOW
```

| Setting | Required | Meaning |
|---|---|---|
| `name_prefix` | yes | Prefix for the ZIA objects this creates |
| `allowed_urls` | no | Domains to allow |
| `blocked_urls` | no | Domains to block |
| `default_action` | no (`ALLOW`) | `BLOCK`: only the allow list works. `ALLOW`: everything except the block list. |
| `location_names` | no | **Leave it out.** `deploy.sh` fills in the gateway's location automatically. |

> Until the gateway exists, the rules are created **disabled**. A ZIA rule
> without a location would apply to your whole tenant, so this is a safety
> net.

### 5.4 Gateway (Phase 2): `stacks/02-ztgw/env/$ZTGW_ENV.tfvars`

```bash
cp stacks/02-ztgw/env/example.tfvars "stacks/02-ztgw/env/$ZTGW_ENV.tfvars"
```

**Example:**

```hcl
region                = "us-west-2"
availability_zone_ids = ["usw2-az1", "usw2-az2", "usw2-az3"]   # from Step 4

create_account_group     = true      # Phase 3 adds each account to this group
account_group_member_ids = []
additional_aws_accounts  = []        # leave empty when you use Phase 3
```

| Setting | Required | Meaning |
|---|---|---|
| `region` | yes | AWS region; must be the same as `ZTGW_REGION` |
| `availability_zone_ids` | yes | AZ **IDs** from Step 4 |
| `gateway_name` | no | Default `ztgw-<env>-<region>`, e.g. `ztgw-prod-us-west-2` |
| `location_name` | no | Default `<gateway_name>-loc`; must be unique in the tenant |
| `create_account_group` | no (`true`) | Creates the group of AWS accounts that may use the gateway |
| `additional_aws_accounts` | no | AWS account IDs allowed **without** Phase 3 onboarding |

### 5.5 AWS account with a NEW VPC (Phase 3, greenfield)

```bash
cp stacks/03-account-greenfield/env/example.tfvars \
   "stacks/03-account-greenfield/env/$ZTGW_ENV-$ZTGW_ACCOUNT.tfvars"
```

**Example (direct mode):**

```hcl
aws_account_id = "111122223333"      # the workload account (12 digits, in quotes)

vpc_cidr               = "10.20.0.0/16"   # new VPC; must not overlap your other networks
private_subnet_newbits = 8                # /16 + 8 = /24 subnets
```

**Example (assume-role mode).** Add the role to jump into:

```hcl
aws_account_id              = "111122223333"
aws_assume_role_arn         = "arn:aws:iam::111122223333:role/ZscalerAutomation"
aws_assume_role_external_id = "my-external-id"   # only if the role requires one

vpc_cidr = "10.20.0.0/16"
```

| Setting | Required | Meaning |
|---|---|---|
| `aws_account_id` | yes | Workload account. Terraform refuses to touch any other account. |
| `aws_assume_role_arn` | assume-role mode | Role in the workload account |
| `aws_assume_role_external_id` | if the role requires it | |
| `vpc_cidr` | no (`10.0.0.0/16`) | Size `/16` to `/22` |
| `private_subnet_newbits` | no (`8`) | Subnet size |
| `enable_event_forwarding` | no (`false`) | Optional EventBridge forwarding to Zscaler. See [phase3-account.md](phase3-account.md). |
| `region`, `endpoint_service_name`, `availability_zone_ids`, `ztgw_account_group_id` | — | **Leave them out.** They come from the gateway automatically. |

### 5.6 AWS account with an EXISTING VPC (Phase 3, brownfield)

Use this **instead of 5.5** for an account whose VPC already exists. Its
servers' internet route (`0.0.0.0/0`) is moved to the gateway, and moved
back if you roll back or destroy.

```bash
cp stacks/03-account-brownfield/env/example.tfvars \
   "stacks/03-account-brownfield/env/$ZTGW_ENV-$ZTGW_ACCOUNT.tfvars"
```

**Find the values you need.** Set `VPC` to your VPC ID first:

```bash
VPC=vpc-0a1b2c3d4e5f60718
# subnets, with their AZ ID and CIDR
aws ec2 describe-subnets --region "$ZTGW_REGION" --profile ztgw-prod \
  --filters Name=vpc-id,Values=$VPC \
  --query 'Subnets[].[AvailabilityZoneId,SubnetId,CidrBlock]' --output table
# route tables, with the subnets that use them
aws ec2 describe-route-tables --region "$ZTGW_REGION" --profile ztgw-prod \
  --filters Name=vpc-id,Values=$VPC \
  --query 'RouteTables[].{Table:RouteTableId,Subnets:Associations[].SubnetId}' --output json
```

**Example:**

```hcl
aws_account_id = "111122223333"
vpc_id         = "vpc-0a1b2c3d4e5f60718"

# For each AZ: the ONE route table your private (server) subnets in that AZ use
route_table_ids = {
  "usw2-az1" = "rtb-0a1b2c3d4e5f60711"
  "usw2-az2" = "rtb-0a1b2c3d4e5f60712"
}

# For each AZ: a small FREE address range inside the VPC for a new endpoint subnet
endpoint_subnet_cidrs = {
  "usw2-az1" = "10.0.255.0/28"
  "usw2-az2" = "10.0.255.16/28"
}

availability_zone_ids = ["usw2-az1", "usw2-az2"]   # only needed if you use fewer AZs than the gateway

cutover = true      # false = put the original routes back (endpoints stay)
```

| Setting | Required | Meaning |
|---|---|---|
| `aws_account_id`, `aws_assume_role_*` | as in 5.5 | |
| `vpc_id` | yes | The existing VPC |
| `route_table_ids` | yes | One route table per AZ. Each AZ needs its **own** route table, and the AZ IDs must match `availability_zone_ids`. |
| `endpoint_subnet_cidrs` | this **or** the next | Free `/28` ranges for new endpoint subnets |
| `endpoint_subnet_ids` | this **or** the previous | Existing subnets to use for the endpoints. They must not use the route tables above. |
| `availability_zone_ids` | if fewer AZs | Defaults to all of the gateway's AZs |
| `cutover` | no (`true`) | `false` rolls the routes back |

---

## Step 6. Preview (plan)

A plan shows what **would** change, and changes nothing.

```bash
scripts/deploy.sh "$ZTGW_ENV" plan
```

What you should see:
- `02-ztgw`: the gateway, a location template and an account group **to
  add**.
- `01-zia-url-policy`: URL categories and rules **to add**.
- Your workloads: `skipped - no gateway wiring yet`. That's normal before
  the first `up`, because they need the gateway's details first.

If something is wrong (a missing file, a typo, wrong credentials), the plan
says so and nothing has been changed. Fix it and run the plan again.

---

## Step 7. Deploy (up)

```bash
scripts/deploy.sh "$ZTGW_ENV" up
```

Terraform shows each change and asks you to type `yes`. In order:

1. **Gateway** (`02-ztgw`). This can take **up to 30 minutes**, while
   Zscaler builds it and the run waits until the gateway is `HEALTHY`.
2. **Wiring.** The gateway's details are saved for the next steps
   automatically. You don't copy anything.
3. **URL policy** (`01-zia-url-policy`). The rules are now enabled for the
   gateway only.
4. **Each AWS account** in `WORKLOADS`. Onboarding to Zscaler (a few
   minutes), then the VPC and endpoints.

### ✅ Check

```bash
scripts/deploy.sh "$ZTGW_ENV" status
```

```
STACK                                    WORKSPACE                    RESOURCES
02-ztgw                                  prod                         6
01-zia-url-policy                        prod                         6
03-account-greenfield@app1               prod-app1                    27
```

Every row should show a number above 0. In the Zscaler portal, the gateway
shows as **Healthy**, and the AWS account appears under Partner
Integrations with its discovery permissions **Allowed**.

Running `up` again is safe: it changes only what's different.

---

## Step 8. Everyday tasks

| I want to… | Do this |
|---|---|
| Change the allow or block lists | Edit `stacks/01-zia-url-policy/env/$ZTGW_ENV.tfvars`, then `scripts/deploy.sh "$ZTGW_ENV" up` |
| Add an AWS account | Pick a new name (`export ZTGW_ACCOUNT=app2`), create its tfvars (5.5 or 5.6), add it to `WORKLOADS`, then `scripts/deploy.sh "$ZTGW_ENV" up` |
| Work on one account only | `scripts/run.sh "$ZTGW_ENV" 03-account-greenfield@$ZTGW_ACCOUNT plan` (or `apply`) |
| Roll back an existing VPC's routes | Set `cutover = false` in its tfvars, then `scripts/run.sh "$ZTGW_ENV" 03-account-brownfield@$ZTGW_ACCOUNT apply` |
| Remove one account | Remove it from `WORKLOADS`, then `scripts/run.sh "$ZTGW_ENV" <stack>@<account name> destroy` |
| Remove everything | `scripts/deploy.sh "$ZTGW_ENV" down`. It asks you to type the env name, then removes the accounts, the policy and the gateway, in that order. Existing VPCs get their original routes back. |
| Run without prompts (CI) | Put `AUTO_APPROVE=1` in front: `AUTO_APPROVE=1 scripts/deploy.sh "$ZTGW_ENV" up` |
| See every option | `scripts/deploy.sh --help`, `scripts/run.sh --help` |

> **Keep the `terraform.tfstate.d` folders.** They are Terraform's memory of
> what it built (one inside each `stacks/...` folder). Back them up. Without
> them, Terraform can't update or remove what it created.

---

## Step 9. If something goes wrong

| Message | What it means | Fix |
|---|---|---|
| `has mode 644; run: chmod 600 ...` | The credentials file is readable by others | Run the `chmod 600` command shown |
| `missing config/prod.env` / `missing .../prod.tfvars` | A file from Step 5 is missing, or has a different env name | Create it; check the spelling of `ZTGW_ENV` |
| `unknown key 'ZSCALER_CLIENTID'` | Typo in a `.env` or `.deploy` file | Fix the key name (see the tables in Step 5) |
| `missing required setting(s) for auth mode ...` | A required value in the `.env` file is empty | Fill it in (see 5.1) |
| `terraform >= 1.7 required (found 1.5)` | Terraform is too old | See Step 1 (macOS: use `hashicorp/tap/terraform`) |
| `AWS account ID not allowed` | The AWS profile signs in to a different account than `aws_account_id` | Check `aws sts get-caller-identity --profile ...`; fix the profile or the ID |
| `ExpiredToken` / `SSO session expired` | AWS login expired | `aws sso login --profile ztgw-prod` |
| `pending activation changes` | Someone else has unactivated changes in the Zscaler tenant | Activate (or discard) them in the portal, then run again |
| `region ... is not supported` | Your tenant can't build a gateway in that region | Choose a supported region |
| `not HEALTHY after 1800s` | Zscaler is still building the gateway | Wait, then run `up` again; it picks up where it stopped |
| `no gateway wiring` | A workload ran before the gateway | Run `scripts/deploy.sh "$ZTGW_ENV" up` (with `GATEWAY=true`), or `... wire` |

More detail: [deployment.md](deployment.md) (how `deploy.sh` works),
[authentication.md](authentication.md), and the phase guides
[1](phase1-zia-url-policy.md), [2](phase2-ztgw.md) and
[3](phase3-account.md).

---

## Cheat sheet

```bash
# once per terminal
export ZTGW_ENV=prod ZTGW_ACCOUNT=app1 ZTGW_REGION=us-west-2

# once per environment
cp config/example.env    "config/$ZTGW_ENV.env" && chmod 600 "config/$ZTGW_ENV.env"
cp config/example.deploy "config/$ZTGW_ENV.deploy"
cp stacks/01-zia-url-policy/env/example.tfvars     "stacks/01-zia-url-policy/env/$ZTGW_ENV.tfvars"
cp stacks/02-ztgw/env/example.tfvars               "stacks/02-ztgw/env/$ZTGW_ENV.tfvars"
# once per AWS account
cp stacks/03-account-greenfield/env/example.tfvars "stacks/03-account-greenfield/env/$ZTGW_ENV-$ZTGW_ACCOUNT.tfvars"

# edit the files, then
scripts/run.sh    "$ZTGW_ENV" 02-ztgw auth-check
scripts/deploy.sh "$ZTGW_ENV" plan
scripts/deploy.sh "$ZTGW_ENV" up
scripts/deploy.sh "$ZTGW_ENV" status
scripts/deploy.sh "$ZTGW_ENV" down
```
