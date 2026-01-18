# Ephemeral Environments

This sort of thing should be commoditized at this point, right?

Spin up temporary environments for pull requests. Each PR gets its own isolated environment with a public URL.

## How It Works

```
GitHub PR Event → Cloudflare Worker → SQS → Lambda
                                              ├─ Launch EC2
                                              ├─ Clone repo and run docker-compose
                                              ├─ Create Cloudflare Quick Tunnel
                                              └─ Post URL to GitHub PR
```

When you open a PR, the system:
1. Receives the webhook and queues a deployment
2. Launches an EC2 instance from a pre-built AMI
3. Clones your branch and starts services with Docker Compose
4. Creates a public tunnel URL
5. Comments the URL on your PR

Environments stop after 4 hours idle and terminate after 24 hours stopped. A reconciler runs every 30 minutes to clean up orphaned instances from closed PRs.

## Quick Start

```bash
# Copy and configure environment
cp .env.example .env
# Edit .env with your AWS, Cloudflare, and GitHub credentials

# Deploy everything
make deploy
```

## Commands

| Command | Purpose |
|---------|---------|
| `make deploy` | Full deployment (Terraform + AMI + Worker + Lambda) |
| `make destroy` | Tear down all infrastructure |
| `make tf-plan` | Preview infrastructure changes |
| `make tf-apply` | Apply infrastructure changes |
| `make ami-build` | Build the EC2 environment AMI |
| `make worker-dev` | Run Cloudflare Worker locally (port 8787) |
| `make worker-deploy` | Deploy Worker to Cloudflare |
| `make lambda-update` | Rebuild and deploy Lambda functions |
| `make test-e2e` | Run end-to-end tests |

## Architecture

| Component | Location | Role |
|-----------|----------|------|
| Webhook Handler | `worker/src/index.ts` | Receives GitHub webhooks, queues to SQS |
| Deploy Lambda | `src/deployer/` | Orchestrates EC2, tunnels, and GitHub updates |
| Cleanup Lambda | `src/cleanup/` | Auto-stops idle environments |
| Reconciler Lambda | `src/reconciler/` | Terminates orphans, reconciles state |
| AWS Infrastructure | `infra/aws/` | Terraform for EC2, Lambda, SQS, DynamoDB, VPC |
| AMI Builder | `packer/` | Amazon Linux 2023 with Docker and cloudflared |

## Integrating Your Project

This repo includes a Claude Code plugin that helps integrate any project with the ephemeral environment system.

### Install the Plugin

```bash
/plugin marketplace add jack-michaud/ephemeral-environments
/plugin install ephemeral-environments@ephemeral-environments
```

### Use the /integrate Command

In your project directory, run:

```bash
/integrate
```

The command analyzes your project and:
1. Checks for a compatible `docker-compose.yml`
2. Verifies port 80 is exposed
3. Detects your tech stack and dependencies
4. Generates configuration if needed

### Requirements

Your project needs:
- A `docker-compose.yml` that exposes port 80
- A Dockerfile that builds your application
- The GitHub App installed on your repository

**Example docker-compose.yml:**
```yaml
services:
  app:
    build: .
    ports:
      - "80:3000"  # Expose your app on port 80
```

## Setup

### GitHub App

The system uses a GitHub App to receive webhooks and post comments. Run the setup script:

```bash
./scripts/setup-github-app.sh
```

This guides you through creating an app with minimal permissions:
- **Contents**: Read (clone repos)
- **Commit statuses**: Write (post status checks)
- **Pull requests**: Write (post comments)

After creating the app, save the private key as `github-app.pem` and add the App ID to your `.env`.

### AWS and Cloudflare

Setup scripts create credentials with minimal permissions:

```bash
./scripts/setup-aws-credentials.sh
./scripts/setup-cloudflare-token.sh
```

### Configuration

All settings live in `.env`. See `.env.example` for the full list.

## Performance

Typical end-to-end deployment times from webhook to environment ready:

| Phase | Duration | Description |
|-------|----------|-------------|
| Webhook → Lambda | ~1s | Cloudflare Worker queues to SQS |
| Secrets + Auth | ~3s | Fetch Cloudflare/GitHub credentials |
| EC2 Launch | ~10-15s | Request instance from launch template |
| Instance Ready | ~30-45s | Wait for instance to pass status checks |
| SSM Bootstrap | ~180-240s | Clone repo, docker-compose build/up, tunnel start |
| **Total** | **~4-5 min** | End-to-end deployment |

**Rebuild times** (existing environment): ~2-3 min (no EC2 launch wait)

**Cleanup times**:
- Auto-stop (4h idle): Immediate stop, ~30s
- Terminate (24h stopped): Immediate terminate, ~15s
- Reconciler cleanup: Every 30 min scan

*Metrics last validated: 2026-01-18*

## Tech Stack

- **TypeScript**: Cloudflare Worker
- **Python 3.11**: Lambda functions (boto3, PyGithub)
- **Terraform**: AWS and Cloudflare infrastructure
- **Packer**: AMI builds
- **Docker Compose**: Application runtime
