# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Development Commands

```bash
# Full deployment
make deploy              # Complete deployment (terraform + AMI + worker + lambda)
make destroy             # Full teardown

# Terraform
make tf-init             # Initialize Terraform
make tf-plan             # Show infrastructure changes
make tf-apply            # Apply infrastructure changes

# AMI
make ami-build           # Build EC2 environment AMI with Packer

# Cloudflare Worker
make worker-dev          # Run worker locally on port 8787
make worker-deploy       # Deploy to Cloudflare
make worker-secrets      # Set worker secrets from .env

# Lambda functions
make lambda-package      # Package Python Lambda functions into zips
make lambda-update       # Rebuild and deploy Lambda functions

# Testing
make test-e2e            # Run E2E tests with pytest
```

## Deploy & Test Workflow

Before completing any code changes, run the applicable quality gates:

```bash
make tf-apply        # If terraform/infra changes
make lambda-package  # Build Lambda zips
make lambda-update   # Deploy Lambda functions
make test-e2e        # Run E2E tests
```

## Session Completion

When ending a work session, complete ALL steps. Work is NOT complete until push succeeds.

1. **File issues for remaining work** - Create bd issues for anything needing follow-up
2. **Run quality gates** (if code changed) - See "Deploy & Test Workflow" above
3. **Update issue status** - Close finished work with `bd close <id>`
4. **Commit and push**:
   ```bash
   jj describe -m "commit message"    # Describe current revision
   jj bookmark set main -r @          # Update main to current revision
   jj new                             # Start new empty revision
   jj git push -b main                # Push main to remote
   ```
5. **Verify** - Confirm push succeeded

**Critical:** Work is NOT complete until `jj git push` succeeds. Never stop before pushing.

## Architecture Overview

GitHub webhook-driven ephemeral environment system that creates temporary environments for PRs:

```
GitHub PR Event → Cloudflare Worker → SQS → Lambda Deploy Worker
                                              ├→ EC2 launch
                                              ├→ SSM: git clone + docker-compose up
                                              ├→ Cloudflare Quick Tunnel
                                              ├→ GitHub status/comment with URL
                                              └→ DynamoDB state tracking
```

Scheduled cleanup:
- **Cleanup Lambda**: Auto-stop after 4h idle, terminate after 24h stopped
- **Reconciler Lambda**: Every 30min, terminates orphaned instances for closed PRs

## Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| Webhook Handler | `worker/src/index.ts` | TypeScript Cloudflare Worker - receives GitHub webhooks, routes to SQS |
| Deploy Lambda | `src/deployer/handler.py` | Main orchestration - EC2 launch, SSM commands, tunnel setup, GitHub API |
| Cleanup Lambda | `src/cleanup/handler.py` | Scheduled auto-stop/terminate for cost control |
| Reconciler Lambda | `src/reconciler/handler.py` | Orphan detection, state reconciliation |
| AWS Infra | `infra/aws/` | Terraform: EC2, Lambda, SQS, DynamoDB, VPC |
| AMI Builder | `packer/environment-ami.pkr.hcl` | Amazon Linux 2023 with Docker, cloudflared |

## Key Files for Common Tasks

**Adding Lambda functionality:**
- Entry points: `src/{deployer,cleanup,reconciler}/handler.py`
- EC2 operations: `src/deployer/ec2_manager.py`
- Remote commands: `src/deployer/ssm_commands.py`
- Cloudflare API: `src/deployer/cloudflare_api.py`

**Modifying webhook handling:**
- Worker code: `worker/src/index.ts`
- Config: `worker/wrangler.toml`

**Infrastructure changes:**
- AWS: `infra/aws/*.tf`
- Cloudflare: `infra/cloudflare/*.tf`

## Tech Stack

- **TypeScript**: Cloudflare Worker (webhook handler)
- **Python 3.11**: AWS Lambda functions (boto3, PyGithub)
- **Terraform**: Infrastructure (AWS + Cloudflare)
- **Packer**: AMI building
- **Docker Compose**: Environment runtime

## Configuration

All configuration via `.env` file (see `.env.example`). Key variables:
- AWS credentials and region
- Cloudflare account/zone IDs and API tokens
- GitHub App ID and installation ID

## DynamoDB Tables

- `ephemeral-environments`: Active environments (PK: `repo#pr_number`)
- `ephemeral-builds`: Build history (PK: `environment_id`, SK: `build_id`)

## Tunnel Approach

Uses Cloudflare Quick Tunnels (`cloudflared tunnel --url`) for zero-config DNS. See `docs/TUNNEL_APPROACHES.md` for design rationale.