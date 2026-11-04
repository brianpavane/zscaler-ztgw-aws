# Deploying an environment

`scripts/deploy.sh` deploys, plans or removes a whole environment in phase
order. It passes the gateway's outputs to the other phases automatically, so
nothing is copied by hand. Each step is an ordinary `scripts/run.sh` call, so
credentials, workspaces, activation and the brownfield route restore behave
exactly as when you run a stack on its own.

```
scripts/deploy.sh <env> plan | up | down | status | wire
make up ENV=<env>           # same, via make
```

## Packaging: what you fill in

An environment (`<env>`, e.g. `zs2` or `prod`) is one Zscaler tenant. You
provide:

| File | Contents | Tracked in git? |
|---|---|---|
| `config/<env>.env` (mode 600) | Zscaler credentials (OneAPI or Legacy), `AWS_PROFILE` | No |
| `config/<env>.deploy` | Which parts this environment contains | No |
| `stacks/01-zia-url-policy/env/<env>.tfvars` | URL allow/block lists, default action | No |
| `stacks/02-ztgw/env/<env>.tfvars` | Gateway region, AZs | No |
| `stacks/03-account-*/env/<env>-<instance>.tfvars` | One per AWS account: account ID, auth mode, VPC settings | No |

Every file has a commented `example` next to it. Generated files
(`*.wiring.tfvars.json`) and state are git-ignored too.

### `config/<env>.deploy`

```bash
URL_POLICY=true      # Phase 1
GATEWAY=true         # Phase 2
# Phase 3: one entry per AWS account, <stack>@<instance>
WORKLOADS="03-account-greenfield@app1 03-account-greenfield@app2 03-account-brownfield@core"
```

Each workload instance has its own Terraform workspace (`<env>-<instance>`)
and tfvars file (`env/<env>-<instance>.tfvars`), so accounts are independent:
adding, changing or removing one never plans changes to another, or to the
gateway.

## What each command does

### `up`

1. **Preflight:** every selected stack has its tfvars file. Nothing runs
   otherwise.
2. `02-ztgw apply`: create or update the gateway, waiting until it is HEALTHY.
3. **Wiring:** read the gateway's outputs and write
   `stacks/<stack>/env/<env>.wiring.tfvars.json`:

   | Stack | Values |
   |---|---|
   | `01-zia-url-policy` | `location_names = [<gateway location>]` |
   | `03-account-*` | `region`, `endpoint_service_name`, `availability_zone_ids`, `ztgw_account_group_id` |

4. `01-zia-url-policy apply`: rules scoped to the gateway location, enabled
   and activated.
5. Each workload, in the listed order: onboard the account (WDS, account
   group, optional event forwarding) and build or attach its VPC.

`up` is idempotent: re-running it applies only what changed. To add an
account, add it to `WORKLOADS`, create its tfvars and run `up` again. The
gateway and the other accounts show no changes.

### `down`

Asks you to type the env name (skipped with `AUTO_APPROVE=1`), then destroys
in reverse order:

1. Workloads, last first. A brownfield workload first restores the original
   default routes.
2. The URL policy. Its rules reference the gateway location.
3. The gateway, then the wiring files are removed.

To remove a single account, take it out of `WORKLOADS` and run
`scripts/run.sh <env> <stack>@<instance> destroy`.

### `plan`

Plans the gateway, the policy and every workload that already has wiring.
Before the first `up`, the workloads have no gateway to point at; they are
skipped with a message rather than failing.

### `status`

```
STACK                                    WORKSPACE                    RESOURCES
02-ztgw                                  zs2                          6
01-zia-url-policy                        zs2                          6
03-account-greenfield@app1               zs2-app1                     27
03-account-brownfield@core               zs2-core                     14
```

### `wire`

Rewrites the wiring files from the gateway's current outputs. `up` does this
automatically. Use it when the gateway is managed separately (`GATEWAY=false`)
or after changing the gateway with `run.sh`.

## Precedence

`run.sh` loads `env/<env>.wiring.tfvars.json` **before** the stack's tfvars,
so a value set in tfvars always wins. Leave the wired values out of tfvars
unless you mean to override them. For example, set `availability_zone_ids`
in a workload's tfvars to use only some of the gateway's AZs.

## Running stacks individually

Everything `deploy.sh` does can be done step by step:

```bash
scripts/run.sh zs2 02-ztgw apply
scripts/deploy.sh zs2 wire
scripts/run.sh zs2 01-zia-url-policy apply
scripts/run.sh zs2 03-account-greenfield@app1 plan
scripts/run.sh zs2 03-account-greenfield@app1 apply
```

## Unattended runs (CI)

```bash
AUTO_APPROVE=1 scripts/deploy.sh zs2 up
```

`AUTO_APPROVE=1` passes `-auto-approve` to every apply and destroy, and skips
the typed confirmation of `down`. State is local in v1 (see the README); a
CI pipeline needs to keep the `terraform.tfstate.d` directories between runs
until the S3 backend arrives in v2.
