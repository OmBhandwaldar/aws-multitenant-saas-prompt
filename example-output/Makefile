# ---------------------------------------------------------------------------
# Convenience wrapper around Terraform for this repo.
# Usage:
#   make bootstrap                     # one-time: create S3 state + DDB lock
#   make init ENV=dev BUCKET=... TABLE=...
#   make plan ENV=dev
#   make apply ENV=dev
#   make destroy ENV=dev
#   make fmt | make validate | make lint | make outputs
# ---------------------------------------------------------------------------

ENV       ?= dev
REGION    ?= us-east-1
ROOT      := $(shell pwd)
ENV_DIR   := envs/$(ENV)

# Required when running init for the first time. Read these from
# `terraform output` in the bootstrap stack.
BUCKET ?=
TABLE  ?=

.PHONY: help bootstrap init plan apply destroy fmt validate lint clean outputs

help:
	@echo "Targets:"
	@echo "  bootstrap        Create the remote state bucket + lock table (one-time)"
	@echo "  init             Initialize the selected env (ENV=dev|prod, requires BUCKET + TABLE)"
	@echo "  plan             terraform plan for ENV"
	@echo "  apply            terraform apply -auto-approve for ENV"
	@echo "  destroy          terraform destroy -auto-approve for ENV"
	@echo "  fmt              terraform fmt -recursive"
	@echo "  validate         terraform validate for ENV"
	@echo "  lint             tflint + checkov (if installed)"
	@echo "  outputs          terraform output for ENV"
	@echo "  clean            remove .build/ caches"

bootstrap:
	cd bootstrap && terraform init && terraform apply -auto-approve

init:
	@if [ -z "$(BUCKET)" ] || [ -z "$(TABLE)" ]; then \
	  echo "ERROR: pass BUCKET=<state-bucket> TABLE=<lock-table>"; exit 1; fi
	cd $(ENV_DIR) && terraform init -reconfigure \
	  -backend-config="bucket=$(BUCKET)" \
	  -backend-config="region=$(REGION)" \
	  -backend-config="dynamodb_table=$(TABLE)"

plan:
	cd $(ENV_DIR) && terraform plan -out=tfplan

apply:
	cd $(ENV_DIR) && terraform apply -auto-approve

destroy:
	cd $(ENV_DIR) && terraform destroy -auto-approve

fmt:
	terraform fmt -recursive

validate:
	cd $(ENV_DIR) && terraform validate

lint:
	@command -v tflint >/dev/null 2>&1 && tflint --recursive || echo "tflint not installed; skipping"
	@command -v checkov >/dev/null 2>&1 && checkov -d . --quiet || echo "checkov not installed; skipping"

outputs:
	cd $(ENV_DIR) && terraform output

clean:
	find . -type d -name .build -prune -exec rm -rf {} +
	find . -type f -name "*.zip" -path "*/.build/*" -delete
