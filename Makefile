# Ephemeral Environments - Makefile
# All deployment and management commands

.PHONY: help setup setup-aws setup-cloudflare setup-github setup-test-token \
        tf-init tf-plan tf-apply tf-destroy \
        ami-build \
        worker-dev worker-deploy worker-secrets \
        lambda-package lambda-update lambda-deploy \
        deploy destroy \
        test-e2e \
        clean

# Default target
help:
	@echo "Ephemeral Environments - Available Commands"
	@echo ""
	@echo "Setup (run these first!):"
	@echo "  make setup              Create .env from template and run all setup scripts"
	@echo "  make setup-aws          Create AWS IAM user with minimal permissions"
	@echo "  make setup-cloudflare   Create Cloudflare API token with minimal permissions"
	@echo "  make setup-github       Guide to create GitHub App"
	@echo "  make setup-test-token   Create Cloudflare Service Token for E2E tests"
	@echo ""
	@echo "Infrastructure:"
	@echo "  make tf-init            Initialize Terraform (AWS + Cloudflare)"
	@echo "  make tf-plan            Show Terraform plan"
	@echo "  make tf-apply           Apply Terraform changes"
	@echo "  make tf-destroy         Destroy all Terraform resources"
	@echo ""
	@echo "AMI:"
	@echo "  make ami-build          Build environment AMI with Packer"
	@echo ""
	@echo "Cloudflare Worker:"
	@echo "  make worker-dev         Run worker locally for testing"
	@echo "  make worker-deploy      Deploy worker to Cloudflare"
	@echo "  make worker-secrets     Set all worker secrets from .env"
	@echo ""
	@echo "Lambda:"
	@echo "  make lambda-package     Package Lambda functions"
	@echo "  make lambda-update      Rebuild and deploy Lambda functions"
	@echo "  make lambda-deploy      Deploy Lambda functions"
	@echo ""
	@echo "All-in-one:"
	@echo "  make deploy             Full deployment (tf-apply + ami + worker + lambda)"
	@echo "  make destroy            Full teardown"
	@echo ""
	@echo "Testing:"
	@echo "  make test-e2e           Run end-to-end tests"
	@echo ""

# =============================================================================
# Setup
# =============================================================================

setup: .env
	@echo "Running setup scripts..."
	@echo ""
	@echo "Step 1: AWS Credentials"
	@./scripts/setup-aws-credentials.sh
	@echo ""
	@echo "Step 2: Cloudflare Token"
	@./scripts/setup-cloudflare-token.sh
	@echo ""
	@echo "Step 3: GitHub App"
	@./scripts/setup-github-app.sh
	@echo ""
	@echo "Setup complete! Fill in your .env file with the values above."

.env:
	@cp .env.example .env
	@echo "Created .env from .env.example"

.env.test:
	@cp .env.test.example .env.test
	@echo "Created .env.test from .env.test.example"

setup-aws:
	@./scripts/setup-aws-credentials.sh

setup-cloudflare:
	@./scripts/setup-cloudflare-token.sh

setup-github:
	@./scripts/setup-github-app.sh

setup-test-token: .env.test
	@echo "Creating Cloudflare Service Token for E2E tests..."
	@echo ""
	@echo "1. Go to: https://one.dash.cloudflare.com/ -> Access -> Service Auth"
	@echo "2. Click 'Create Service Token'"
	@echo "3. Name: ephemeral-environments-test"
	@echo "4. Duration: 1 year (or shorter for security)"
	@echo "5. Copy the Client ID and Client Secret"
	@echo ""
	@echo "Add these to .env.test:"
	@echo "  CF_SERVICE_TOKEN_ID=<Client ID>"
	@echo "  CF_SERVICE_TOKEN_SECRET=<Client Secret>"

# =============================================================================
# Infrastructure (Terraform)
# =============================================================================

tf-init:
	@echo "Initializing Terraform..."
	cd infra/aws && terraform init
	cd infra/cloudflare && terraform init

tf-plan: check-env generate-tfvars
	@echo "Planning AWS infrastructure..."
	cd infra/aws && terraform plan
	@echo ""
	@echo "Planning Cloudflare infrastructure..."
	cd infra/cloudflare && terraform plan

tf-apply: check-env generate-tfvars
	@echo "Applying AWS infrastructure..."
	cd infra/aws && terraform apply -auto-approve
	@echo ""
	@echo "Applying Cloudflare infrastructure..."
	cd infra/cloudflare && terraform apply -auto-approve

generate-tfvars: check-env
	@echo "Generating terraform.tfvars from .env..."
	@. ./.env && \
		echo "cloudflare_account_id = \"$$CLOUDFLARE_ACCOUNT_ID\"" > infra/aws/terraform.tfvars && \
		echo "cloudflare_api_token = \"$$CLOUDFLARE_API_TOKEN\"" >> infra/aws/terraform.tfvars && \
		echo "github_app_id = \"$$GITHUB_APP_ID\"" >> infra/aws/terraform.tfvars && \
		echo "github_webhook_secret = \"$$GITHUB_WEBHOOK_SECRET\"" >> infra/aws/terraform.tfvars && \
		echo 'github_app_private_key = <<-EOT' >> infra/aws/terraform.tfvars && \
		cat "$$GITHUB_APP_PRIVATE_KEY_PATH" >> infra/aws/terraform.tfvars && \
		echo "EOT" >> infra/aws/terraform.tfvars && \
		if [ -n "$$ENVIRONMENT_AMI_ID" ]; then echo "environment_ami_id = \"$$ENVIRONMENT_AMI_ID\"" >> infra/aws/terraform.tfvars; fi
	@. ./.env && \
		echo "cloudflare_account_id = \"$$CLOUDFLARE_ACCOUNT_ID\"" > infra/cloudflare/terraform.tfvars && \
		echo "cloudflare_api_token = \"$$CLOUDFLARE_API_TOKEN\"" >> infra/cloudflare/terraform.tfvars
	@echo "Generated infra/aws/terraform.tfvars and infra/cloudflare/terraform.tfvars"

tf-destroy: check-env
	@echo "Destroying Cloudflare infrastructure..."
	cd infra/cloudflare && terraform destroy
	@echo ""
	@echo "Destroying AWS infrastructure..."
	cd infra/aws && terraform destroy

# =============================================================================
# AMI (Packer)
# =============================================================================

ami-build: check-env
	@echo "Building environment AMI..."
	cd packer && packer init . && packer build environment-ami.pkr.hcl

# =============================================================================
# Cloudflare Worker
# =============================================================================

worker-dev: check-env
	@echo "Starting worker in development mode..."
	@. ./.env && cd worker && npm install && CLOUDFLARE_API_TOKEN=$$CLOUDFLARE_API_TOKEN npx wrangler dev

worker-deploy: check-env
	@echo "Deploying worker to Cloudflare..."
	@. ./.env && cd worker && npm install && CLOUDFLARE_API_TOKEN=$$CLOUDFLARE_API_TOKEN npx wrangler deploy

worker-secrets: check-env
	@echo "Setting Cloudflare Worker secrets..."
	@. ./.env && cd worker && \
		echo "Setting GITHUB_WEBHOOK_SECRET..." && \
		printf '%s' "$$GITHUB_WEBHOOK_SECRET" | tr -d '\n\r' | CLOUDFLARE_API_TOKEN=$$CLOUDFLARE_API_TOKEN npx wrangler secret put GITHUB_WEBHOOK_SECRET && \
		echo "Setting AWS_ACCESS_KEY_ID..." && \
		printf '%s' "$$AWS_ACCESS_KEY_ID" | tr -d '\n\r' | CLOUDFLARE_API_TOKEN=$$CLOUDFLARE_API_TOKEN npx wrangler secret put AWS_ACCESS_KEY_ID && \
		echo "Setting AWS_SECRET_ACCESS_KEY..." && \
		printf '%s' "$$AWS_SECRET_ACCESS_KEY" | tr -d '\n\r' | CLOUDFLARE_API_TOKEN=$$CLOUDFLARE_API_TOKEN npx wrangler secret put AWS_SECRET_ACCESS_KEY && \
		echo "Setting AWS_REGION..." && \
		printf '%s' "$$AWS_REGION" | tr -d '\n\r' | CLOUDFLARE_API_TOKEN=$$CLOUDFLARE_API_TOKEN npx wrangler secret put AWS_REGION && \
		echo "Setting SQS_QUEUE_URL..." && \
		printf '%s' "https://sqs.$$AWS_REGION.amazonaws.com/$$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '836556727475')/ephemeral-build-queue" | tr -d '\n\r' | CLOUDFLARE_API_TOKEN=$$CLOUDFLARE_API_TOKEN npx wrangler secret put SQS_QUEUE_URL
	@echo "All worker secrets set successfully!"

# =============================================================================
# Lambda
# =============================================================================

lambda-package:
	@echo "Packaging Lambda functions using Lambda-compatible Docker image..."
	@mkdir -p dist
	docker run --rm --platform linux/amd64 --entrypoint "" -v "$(PWD)/src/deployer:/src:ro" -v "$(PWD)/dist:/dist" public.ecr.aws/lambda/python:3.11 sh -c "\
		yum install -y zip && \
		mkdir /build && cp -r /src/* /build/ && \
		pip install --upgrade -r /build/requirements.txt -t /build && \
		cd /build && zip -r /dist/deployer.zip . -x '*.pyc' -x '__pycache__/*'"
	docker run --rm --platform linux/amd64 --entrypoint "" -v "$(PWD)/src/cleanup:/src:ro" -v "$(PWD)/dist:/dist" public.ecr.aws/lambda/python:3.11 sh -c "\
		yum install -y zip && \
		mkdir /build && cp -r /src/* /build/ && \
		pip install --upgrade -r /build/requirements.txt -t /build && \
		cd /build && zip -r /dist/cleanup.zip . -x '*.pyc' -x '__pycache__/*'"
	@echo "Lambda packages created in dist/"

lambda-update: lambda-package generate-tfvars
	@echo "Deploying Lambda functions via Terraform..."
	cd infra/aws && terraform apply -auto-approve -target=aws_lambda_function.deploy_worker -target=aws_lambda_function.cleanup_worker
	@echo "Lambda functions updated!"

lambda-deploy: lambda-package check-env
	@echo "Deploying Lambda functions..."
	@echo "TODO: Upload to S3 and update Lambda"

# =============================================================================
# All-in-one
# =============================================================================

deploy: tf-apply ami-build worker-deploy lambda-deploy
	@echo ""
	@echo "=== Deployment Complete ==="
	@echo ""
	@echo "Next steps:"
	@echo "1. Update GitHub App webhook URL with the Cloudflare Worker URL"
	@echo "2. Install the GitHub App on your repositories"
	@echo "3. Open a PR to test!"

destroy: tf-destroy
	@echo ""
	@echo "=== Teardown Complete ==="

# =============================================================================
# Testing
# =============================================================================

test-e2e: .env.test
	@echo "Running E2E tests..."
	@if [ ! -f .env.test ]; then echo "Error: .env.test not found. Run 'make setup-test-token' first."; exit 1; fi
	cd tests && python -m pytest test_pr_lifecycle.py -v

# =============================================================================
# Utilities
# =============================================================================

check-env:
	@if [ ! -f .env ]; then echo "Error: .env not found. Run 'make setup' first."; exit 1; fi
	@. ./.env && \
		if [ -z "$$AWS_ACCESS_KEY_ID" ]; then echo "Error: AWS_ACCESS_KEY_ID not set in .env"; exit 1; fi && \
		if [ -z "$$CLOUDFLARE_API_TOKEN" ]; then echo "Error: CLOUDFLARE_API_TOKEN not set in .env"; exit 1; fi

clean:
	@echo "Cleaning build artifacts..."
	rm -rf dist/
	rm -rf src/deployer/*.dist-info src/deployer/bin
	rm -rf src/cleanup/*.dist-info src/cleanup/bin
	rm -rf worker/node_modules
	@echo "Clean complete"
