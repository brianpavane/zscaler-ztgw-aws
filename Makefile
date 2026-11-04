# Convenience targets. All real logic lives in scripts/.
SHELL := /usr/bin/env bash

.PHONY: help qa fmt validate lint test examples shell wrapper security plan up down status

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

# Environment orchestration (scripts/deploy.sh). Usage: make up ENV=zs2
plan: ## deploy.sh ENV=<env> plan
	@scripts/deploy.sh "$(ENV)" plan

up: ## deploy.sh ENV=<env> up (gateway, policy, workloads)
	@scripts/deploy.sh "$(ENV)" up

down: ## deploy.sh ENV=<env> down (reverse order, typed confirmation)
	@scripts/deploy.sh "$(ENV)" down

status: ## deploy.sh ENV=<env> status
	@scripts/deploy.sh "$(ENV)" status
