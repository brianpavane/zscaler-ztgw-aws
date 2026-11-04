# Convenience targets. All real logic lives in scripts/.
SHELL := /usr/bin/env bash

.PHONY: help qa fmt validate lint test examples shell wrapper security

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

qa: ## Run every offline validation path
	@scripts/qa.sh

fmt: ## Rewrite Terraform files to canonical format
	@terraform fmt -recursive

validate: ## terraform validate every module and stack
	@scripts/qa.sh validate

lint: ## tflint every module and stack
	@scripts/qa.sh tflint

test: ## terraform test (mocked providers)
	@scripts/qa.sh test

examples: ## Plan every example.tfvars against real provider schemas
	@scripts/qa.sh examples

shell: ## shellcheck + wrapper tests
	@scripts/qa.sh shell wrapper

security: ## checkov static security scan
	@scripts/qa.sh checkov
