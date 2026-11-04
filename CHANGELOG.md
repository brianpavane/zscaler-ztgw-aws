# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Phase 2: `stacks/02-ztgw`. Zero Trust Gateway in AWS (default `us-west-2`,
  `usw2-az1..3`, configurable), with a location template, a consumer account
  group, health polling, in-place updates, and destroy-time location cleanup.
  Outputs feed Phase 1 (location) and Phase 3 (endpoint service name).
- `scripts/ztgw/ztgw.py`: standard-library Cloud & Branch Connector client
  for the documented `/ztGateway` API (OneAPI and Legacy).
- QA: Python client tests, mocked example-tfvars tests for ztc stacks, and
  product-aware wrapper tests.

### Changed
- `run.sh`: Legacy mode requires only the credentials of the products a stack
  uses. `destroy` of a ztc stack activates Cloud & Branch Connector changes.

### Fixed
- `run.sh --help` exited with an error.
- Phase 1: `modules/zia-url-policy` and `stacks/01-zia-url-policy`. ZIA URL
  filtering policy with allow and block lists, a default ALLOW/BLOCK action,
  location scoping (staged as DISABLED until scoped) and activation.
- `stacks/zia-activate` utility stack, run automatically after a ZIA
  `destroy`.
- `scripts/run.sh`: per-environment runner with a OneAPI/Legacy auth switch,
  a hardened env-file parser and one workspace per tenant.
- `scripts/qa.sh`: offline QA suite (fmt, validate, tflint, terraform test,
  example plans, shellcheck, wrapper tests, checkov), plus a CI workflow and
  pre-commit hooks.
- Documentation: architecture, authentication, Phase 1, QA.
