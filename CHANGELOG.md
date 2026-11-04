# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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
