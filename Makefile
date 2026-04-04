# ==============================================================================
# AWS Cloud Governance Framework — Makefile
# Usage: make <target> ENV=dev
#
# Prerequisites:
#   - AWS CLI v2 installed and configured (aws configure)
#   - cfn-lint installed: pip install cfn-lint
#   - An S3 artifact bucket (run: make bootstrap ENV=dev)
# ==============================================================================

# ------------------------------------------------------------------------------
# CONFIGURATION — edit these defaults to match your setup
# ------------------------------------------------------------------------------
AWS_REGION      ?= us-east-1
ENV             ?= dev
ACCOUNT_ID      := $(shell aws sts get-caller-identity --query Account --output text)
ARTIFACT_BUCKET := $(ACCOUNT_ID)-cfn-artifacts-$(ENV)
STACK_NAME      := governance-$(ENV)
ALERT_EMAIL     ?= your@email.com
MONTHLY_BUDGET  ?= 50
PROJECT_TAG     ?= cloud-governance
COST_CENTER_TAG ?= engineering

TEMPLATE_DIR    := cloudformation
NESTED_DIR      := $(TEMPLATE_DIR)/nested-stacks
MASTER_TEMPLATE := $(TEMPLATE_DIR)/master-stack.yaml

# Colours for terminal output
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
RESET  := \033[0m

.PHONY: help bootstrap validate lint package deploy-guided destroy status outputs clean

# Default target — show help
help:
	@echo ""
	@echo "$(GREEN)AWS Cloud Governance Framework$(RESET)"
	@echo "────────────────────────────────────────────────────────"
	@echo "  make bootstrap    ENV=dev   Create artifact S3 bucket (first time only)"
	@echo "  make lint                   Run cfn-lint on all templates"
	@echo "  make validate     ENV=dev   Validate all templates with AWS"
	@echo "  make package      ENV=dev   Upload templates to S3"
	@echo "  make deploy-guided ENV=dev  Interactive deploy via CloudFormation console"
	@echo "  make status       ENV=dev   Check stack deployment status"
	@echo "  make outputs      ENV=dev   Print all stack outputs"
	@echo "  make destroy      ENV=dev   Tear down all stacks (prompts for confirmation)"
	@echo "  make clean                  Remove local packaging artifacts"
	@echo ""
	@echo "  ENV options: dev | staging | prod"
	@echo "  Default region: $(AWS_REGION)"
	@echo ""

# ------------------------------------------------------------------------------
# BOOTSTRAP — create the S3 artifact bucket (run once per environment)
# This bucket holds the nested stack templates that CloudFormation pulls
# during deployment. Without it, nested stacks cannot be referenced.
# ------------------------------------------------------------------------------
bootstrap:
	@echo "$(YELLOW)Bootstrapping artifact bucket for ENV=$(ENV)...$(RESET)"
	@aws s3api create-bucket \
		--bucket $(ARTIFACT_BUCKET) \
		--region $(AWS_REGION) \
		$(if $(filter-out us-east-1,$(AWS_REGION)),--create-bucket-configuration LocationConstraint=$(AWS_REGION),) \
		2>/dev/null || echo "Bucket already exists, continuing..."
	@aws s3api put-bucket-versioning \
		--bucket $(ARTIFACT_BUCKET) \
		--versioning-configuration Status=Enabled
	@aws s3api put-public-access-block \
		--bucket $(ARTIFACT_BUCKET) \
		--public-access-block-configuration \
		"BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
	@aws s3api put-bucket-encryption \
		--bucket $(ARTIFACT_BUCKET) \
		--server-side-encryption-configuration \
		'{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
	@echo "$(GREEN)Artifact bucket ready: s3://$(ARTIFACT_BUCKET)$(RESET)"
	# Add to Makefile under bootstrap, then run: make bootstrap-stackset-roles
bootstrap-stackset-roles:
	aws cloudformation create-stack \
		--stack-name stackset-roles \
		--template-url https://s3.amazonaws.com/cloudformation-stackset-sample-templates-us-east-1/AWSCloudFormationStackSetAdministrationRole.yml \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION)

# ------------------------------------------------------------------------------
# LINT — run cfn-lint on all templates
# cfn-lint catches CloudFormation-specific errors that generic YAML linters miss.
# Install: pip install cfn-lint
# ------------------------------------------------------------------------------
lint:
	@echo "$(YELLOW)Linting CloudFormation templates...$(RESET)"
	@cfn-lint $(MASTER_TEMPLATE) --include-checks W
	@cfn-lint $(NESTED_DIR)/budget-enforcement.yaml --include-checks W
	@cfn-lint $(NESTED_DIR)/security-baseline.yaml --include-checks W
	@cfn-lint $(NESTED_DIR)/drift-detection.yaml --include-checks W
	@cfn-lint $(NESTED_DIR)/logging-audit.yaml --include-checks W
	@echo "$(GREEN)All templates passed lint checks.$(RESET)"

# ------------------------------------------------------------------------------
# VALIDATE — validate templates against the AWS CloudFormation API
# This catches resource-level errors that cfn-lint can miss. Requires AWS creds.
# ------------------------------------------------------------------------------
validate:
	@echo "$(YELLOW)Validating templates against AWS CloudFormation API...$(RESET)"
	@aws cloudformation validate-template \
		--template-body file://$(MASTER_TEMPLATE) \
		--region $(AWS_REGION) > /dev/null
	@aws cloudformation validate-template \
		--template-body file://$(NESTED_DIR)/budget-enforcement.yaml \
		--region $(AWS_REGION) > /dev/null
	@aws cloudformation validate-template \
		--template-body file://$(NESTED_DIR)/security-baseline.yaml \
		--region $(AWS_REGION) > /dev/null
	@aws cloudformation validate-template \
		--template-body file://$(NESTED_DIR)/drift-detection.yaml \
		--region $(AWS_REGION) > /dev/null
	@aws cloudformation validate-template \
		--template-body file://$(NESTED_DIR)/logging-audit.yaml \
		--region $(AWS_REGION) > /dev/null
	@echo "$(GREEN)All templates valid.$(RESET)"

# ------------------------------------------------------------------------------
# PACKAGE — upload nested stack templates to S3
# CloudFormation nested stacks MUST be in S3 — they cannot be deployed from
# local paths. This syncs the templates to the artifact bucket.
# ------------------------------------------------------------------------------
package:
	@echo "$(YELLOW)Uploading nested stack templates to S3...$(RESET)"
	@aws s3 sync $(NESTED_DIR)/ \
		s3://$(ARTIFACT_BUCKET)/$(AWS_REGION)/nested-stacks/ \
		--region $(AWS_REGION) \
		--exclude "*.md" \
		--delete
	@echo "$(GREEN)Templates uploaded to s3://$(ARTIFACT_BUCKET)/$(AWS_REGION)/nested-stacks/$(RESET)"

# ------------------------------------------------------------------------------
# DEPLOY-GUIDED — opens the CloudFormation console create/update stack wizard.
# Use this when you want to walk through parameters visually — good for demos.
# ------------------------------------------------------------------------------
deploy-guided:
	@echo "$(YELLOW)Opening CloudFormation console for guided deployment...$(RESET)"
	@aws cloudformation package \
		--template-file $(MASTER_TEMPLATE) \
		--s3-bucket $(ARTIFACT_BUCKET) \
		--s3-prefix $(AWS_REGION)/nested-stacks \
		--output-template-file packaged-master.yaml \
		--region $(AWS_REGION)
	@echo "$(GREEN)Packaged template written to packaged-master.yaml$(RESET)"
	@echo "Upload this file to the CloudFormation console to deploy with the visual wizard."

# ------------------------------------------------------------------------------
# STATUS — check the current status of all stacks
# ------------------------------------------------------------------------------
status:
	@echo "$(YELLOW)Stack status for ENV=$(ENV):$(RESET)"
	@aws cloudformation describe-stacks \
		--region $(AWS_REGION) \
		--query 'Stacks[?contains(StackName, `$(ENV)`)].{Name:StackName,Status:StackStatus,Updated:LastUpdatedTime}' \
		--output table 2>/dev/null || echo "No stacks found for ENV=$(ENV)"

# ------------------------------------------------------------------------------
# OUTPUTS — print all stack outputs in a readable format
# ------------------------------------------------------------------------------
outputs:
	@echo "$(YELLOW)Stack outputs for $(STACK_NAME):$(RESET)"
	@aws cloudformation describe-stacks \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--query 'Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}' \
		--output table 2>/dev/null || echo "Stack $(STACK_NAME) not found or not yet deployed."

# ------------------------------------------------------------------------------
# DESTROY — tear down all stacks for the given environment
# Prompts for confirmation — you do NOT want to accidentally run this on prod.
# ------------------------------------------------------------------------------
destroy:
	@echo "$(RED)WARNING: This will DELETE all resources in the $(ENV) environment.$(RESET)"
	@echo "Stack to be deleted: $(STACK_NAME)"
	@read -p "Type the environment name to confirm ($(ENV)): " confirm && \
		[ "$$confirm" = "$(ENV)" ] || (echo "Aborted." && exit 1)
	@echo "$(YELLOW)Deleting stack $(STACK_NAME)...$(RESET)"
	@aws cloudformation delete-stack \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION)
	@echo "Waiting for deletion to complete..."
	@aws cloudformation wait stack-delete-complete \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION)
	@echo "$(GREEN)Stack $(STACK_NAME) deleted successfully.$(RESET)"

# ------------------------------------------------------------------------------
# CLEAN — remove local packaging artifacts
# ------------------------------------------------------------------------------
clean:
	@rm -f packaged-*.yaml
	@echo "$(GREEN)Cleaned packaging artifacts.$(RESET)"
