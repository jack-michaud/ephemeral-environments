# Ephemeral Environments Platform - Implementation Plan

## Overview
Build a platform that automatically deploys isolated environments when GitHub PRs are opened, provides unique URLs, and rebuilds on code changes.

## Architecture (Cloudflare + AWS Hybrid)

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   GitHub PR     │────▶│  Cloudflare      │────▶│  SQS Queue      │
│   (webhook)     │     │  Worker          │     │  (AWS)          │
└─────────────────┘     └──────────────────┘     └────────┬────────┘
                                                          │
                        ┌──────────────────┐              ▼
                        │  Cloudflare      │     ┌─────────────────┐
┌─────────────────┐     │  Access (SSO)    │     │  Deploy Worker  │
│  User Browser   │────▶│  + Tunnel        │     │  (Lambda)       │
└─────────────────┘     └────────┬─────────┘     └─────────────────┘
                                 │                        │
                                 ▼                        ▼
                        ┌──────────────────┐     ┌─────────────────┐
                        │  EC2 Instance    │◀────│  DynamoDB       │
                        │  (docker-compose │     │  (state)        │
                        │   + cloudflared) │     └─────────────────┘
                        └──────────────────┘
```

**Key: Cloudflare handles routing + auth, EC2 runs docker-compose, ~$0 idle cost**

## Core Components

### 1. GitHub App
- **Purpose**: Receive webhooks, post status checks, comment on PRs
- **Permissions**: `pull_requests:write`, `statuses:write`, `contents:read`
- **Webhook URL**: Points to Cloudflare Worker
- **Installation**: Installed on repos that want ephemeral environments

### 2. Cloudflare Worker (Webhook Handler)
- **Tech**: Cloudflare Workers (TypeScript)
- **Receives**: `pull_request` events (opened, synchronize, closed)
- **Actions**:
  - Validate webhook signature (GitHub App secret)
  - Send message to SQS via AWS SDK
  - Return 200 immediately (async processing)
- **Cost**: Free tier covers 100k requests/day

### 3. Deploy Worker (AWS Lambda)
- **Tech**: Lambda (Python) + SSM Run Command
- **Triggered by**: SQS queue
- **Process**:
  1. Launch EC2 instance from pre-baked AMI
  2. Clone repo via SSM Run Command
  3. Inject secrets as .env file
  4. Run `docker-compose up -d`
  5. Start cloudflared tunnel → get tunnel UUID
  6. Configure Cloudflare Access policy (GitHub SSO) for tunnel
  7. Store metadata in DynamoDB (incl. tunnel URL)
  8. **Post to GitHub PR** (via GitHub App):
     - Commit status check: "Environment ready" with URL
     - PR comment: "🚀 Environment deployed: https://<uuid>.cfargotunnel.com"

### 4. EC2 Environment Instances
- **AMI**: Amazon Linux 2023 + Docker + docker-compose + cloudflared
- **Instance type**: t3.small default (can configure per-repo)
- **Lifecycle**: Start on PR open, stop on PR close, terminate after 24h stopped
- **Security**: Private subnet, NO public IP, only outbound to Cloudflare
- **Tunnel**: cloudflared creates outbound tunnel to Cloudflare edge

### 5. Cloudflare Tunnel + Access
- **Tunnel**: Each EC2 runs cloudflared, exposes compose services
- **URL**: `https://<tunnel-uuid>.cfargotunnel.com` (no custom domain needed)
- **Access**: GitHub SSO gate via Access policy on tunnel
- **Cost**: FREE for tunnels, Access free for 50 users
- **Future**: Can add custom domain later for prettier URLs

### 6. State Database (DynamoDB)
```
environments table:
  - PK: repo#pr_number
  - ec2_instance_id, tunnel_id, status
  - url, created_at, updated_at

builds table:
  - PK: environment_id, SK: build_id
  - commit_sha, status, logs_url
```
**Cost**: Pay-per-request, ~$0 for low usage

### 7. Cleanup Worker
- **Tech**: EventBridge + Lambda
- Runs every 15 minutes
- Stops instances for closed PRs
- Deletes Cloudflare tunnels + DNS records
- Auto-stop after 4 hours idle

## File Structure

```
ephemeral-environments/
├── infra/
│   ├── aws/                    # Terraform for AWS
│   │   ├── main.tf             # Provider, backend
│   │   ├── vpc.tf              # VPC, private subnets (no NAT)
│   │   ├── ec2.tf              # Launch template, security groups
│   │   ├── lambda.tf           # Deploy worker, cleanup worker
│   │   ├── dynamodb.tf         # State tables
│   │   ├── sqs.tf              # Build queue
│   │   └── variables.tf
│   └── cloudflare/             # Terraform for Cloudflare
│       ├── main.tf             # Provider config
│       ├── access.tf           # Access application + GitHub IdP
│       └── variables.tf
├── packer/
│   └── environment-ami.pkr.hcl # Docker + compose + cloudflared
├── scripts/
│   ├── setup-aws-credentials.sh    # Create IAM user with minimal perms
│   ├── setup-cloudflare-token.sh   # Create API token with minimal perms
│   └── setup-github-app.sh         # Guide to create GitHub App
├── Makefile                    # All deployment commands
├── .env.example                # Template for required credentials
├── tests/
│   ├── conftest.py             # Pytest fixtures
│   └── test_pr_lifecycle.py    # E2E: full PR lifecycle test
├── worker/                     # Cloudflare Worker (webhook)
│   ├── src/
│   │   └── index.ts            # Webhook handler
│   ├── wrangler.toml
│   └── package.json
├── src/
│   ├── deployer/               # AWS Lambda - deploy worker
│   │   ├── ec2_manager.py      # Launch/stop/terminate
│   │   ├── cloudflare_api.py   # Tunnel + DNS + Access APIs
│   │   ├── ssm_commands.py     # Run commands on instances
│   │   └── handler.py          # Lambda entry point
│   ├── cleanup/                # AWS Lambda - cleanup worker
│   │   └── handler.py
│   └── shared/
│       ├── dynamodb.py         # DynamoDB client
│       └── config.py
└── README.md
```

## Implementation Phases

### Phase 0: Credentials & Setup (First!)
1. Run `make setup` to create `.env` from `.env.example`
2. Run `scripts/setup-aws-credentials.sh` → get AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
3. Run `scripts/setup-cloudflare-token.sh` → get CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID
4. Run `scripts/setup-github-app.sh` → create GitHub App, get credentials
5. Create test GitHub repo for E2E tests
6. Run `make setup-test-token` → create Cloudflare Service Token for tests
7. Fill in `.env` and `.env.test` with all credentials
**Now you're unblocked for all subsequent phases!**

### Phase 1: Infrastructure (Terraform)
1. AWS: VPC with private subnets only (no NAT needed)
2. AWS: DynamoDB tables (environments, builds)
3. AWS: SQS queue for build jobs
4. AWS: IAM roles (Lambda, EC2 instance profile)
5. Cloudflare: Access application with GitHub IdP
6. Packer: AMI with Docker + docker-compose + cloudflared
Run: `make tf-apply && make ami-build`

### Phase 2: Webhook Handler (Cloudflare Worker)
1. TypeScript worker to receive GitHub webhooks
2. Webhook signature validation
3. SQS message publishing (via AWS SDK)
4. Deploy to Cloudflare Workers
5. Configure GitHub App webhook URL
Run: `make worker-deploy`

### Phase 3: Deploy Worker (AWS Lambda)
1. Lambda triggered by SQS
2. EC2 instance launch from AMI
3. SSM: clone repo + docker-compose up
4. SSM: start cloudflared tunnel (get tunnel UUID)
5. Cloudflare API: add Access policy for tunnel (GitHub SSO)
6. DynamoDB: store environment metadata + tunnel URL
7. GitHub API: post comment with tunnel URL
Run: `make lambda-deploy`

### Phase 4: Lifecycle Management
1. PR closed → Lambda stops instance, deletes tunnel
2. PR sync → SSM: git pull + docker-compose up --build
3. EventBridge: every 15 min check for idle environments
4. Auto-stop after 4 hours, terminate after 24h stopped

### Phase 5: E2E Testing
1. Open PR in test repo
2. Run `make test-e2e`
3. Verify full lifecycle works

## Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Edge/Routing | Cloudflare Tunnel | Zero cost, no public IPs needed |
| Auth | Cloudflare Access | Free GitHub SSO, no custom code |
| Webhook | Cloudflare Worker | Free tier, globally distributed |
| Compute | EC2 instances | Full docker-compose compatibility |
| State | DynamoDB | Pay-per-request, ~$0 idle |
| Remote commands | SSM Run Command | No SSH, works in private subnet |
| IaC | Terraform | Both AWS + Cloudflare providers |

## Environment URL Pattern
```
https://<tunnel-uuid>.cfargotunnel.com
```
Example: `https://abc123-def456.cfargotunnel.com`

Each service in compose gets a path:
- Primary service: root path `/`
- Additional services: `/{service-name}`

**Future upgrade**: Add custom domain for `pr-{number}-{repo}.envs.yourdomain.com`

## Automated Testing

### Test Strategy (Simplified)

**E2E Test** (`tests/e2e/test_pr_lifecycle.py`)
- Full PR lifecycle against deployed infrastructure
- Uses Cloudflare **Service Token** to bypass OAuth (no browser automation needed)
- Run: `make test-e2e` (~3-5 minutes)

### E2E Test Flow

```python
# test_pr_lifecycle.py
def test_full_pr_lifecycle():
    # 1. Create branch + open PR via GitHub API
    pr = github.create_pull_request(test_repo, branch="test-env")

    # 2. Wait for environment URL in PR comments (poll)
    env_url = wait_for_environment_comment(pr, timeout=120)

    # 3. Access environment using Service Token (bypasses OAuth)
    response = requests.get(env_url, headers={
        "CF-Access-Client-Id": os.environ["CF_SERVICE_TOKEN_ID"],
        "CF-Access-Client-Secret": os.environ["CF_SERVICE_TOKEN_SECRET"]
    })
    assert response.status_code == 200

    # 4. Push commit, wait for rebuild
    github.push_commit(pr.branch, "test change")
    wait_for_rebuild_comment(pr)

    # 5. Close PR
    github.close_pull_request(pr)

    # 6. Verify cleanup (tunnel deleted)
    time.sleep(30)
    assert not tunnel_exists(env_url)
```

### Test Credentials

```bash
# .env.test
TEST_GITHUB_REPO=your-org/ephemeral-envs-test
TEST_GITHUB_TOKEN=ghp_xxx

# Cloudflare Service Token (created via make setup-test-token)
CF_SERVICE_TOKEN_ID=xxx
CF_SERVICE_TOKEN_SECRET=yyy
```

### Makefile Test Commands

```makefile
make test-e2e           # Run E2E test
make setup-test-token   # Create Cloudflare Service Token for tests
```

## Manual Verification (Smoke Test)
1. Create test repo with simple docker-compose.yml (nginx hello world)
2. Open PR → verify Cloudflare Worker receives webhook
3. Check SQS message queued, Lambda triggered
4. Verify EC2 instance launches, docker-compose runs
5. Verify cloudflared tunnel established
6. Access `https://<tunnel-uuid>.cfargotunnel.com` → see app
7. Verify Cloudflare Access prompts for GitHub login
8. Push commit → verify rebuild triggers
9. Close PR → verify instance stops, tunnel deleted

## Cost Analysis: Scale to Zero

### When Idle ($0/month)
| Service | Idle Cost |
|---------|-----------|
| Cloudflare Workers | $0 (free tier) |
| Cloudflare Tunnel | $0 (free) |
| Cloudflare Access | $0 (free for 50 users) |
| DynamoDB | $0 (free tier: 25GB, 25 WCU/RCU) |
| SQS | $0 (free tier: 1M requests) |
| Lambda | $0 (free tier: 1M requests) |
| **Total Idle** | **~$0/month** |

### Per Environment (when running)
| Service | Cost |
|---------|------|
| EC2 t3.small | $0.0208/hour (~$15/mo if 24/7) |
| EBS (8GB) | ~$0.80/month |
| **Per env/hour** | **~$0.02** |

### With Auto-Stop (4 hours)
- Typical PR lifecycle: 4 hours active → stopped
- Cost per PR: ~$0.08 (4 hours × $0.02)
- 100 PRs/month: ~$8/month

## Configuration

| Setting | Value |
|---------|-------|
| Domain | None (using tunnel UUIDs for now) |
| Auth | Cloudflare Access + GitHub SSO |
| Max Environments | 10-20 concurrent |
| Auto-stop | 4 hours idle |
| Instance type | t3.small (2 vCPU, 2GB RAM) |

## Required Credentials (.env)

```bash
# AWS - created via scripts/setup-aws-credentials.sh
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_REGION=us-east-1

# Cloudflare - created via scripts/setup-cloudflare-token.sh
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=

# GitHub App - created via scripts/setup-github-app.sh
GITHUB_APP_ID=
GITHUB_APP_PRIVATE_KEY_PATH=./github-app.pem
GITHUB_WEBHOOK_SECRET=
```

### Credential Setup Scripts

**scripts/setup-aws-credentials.sh** - Creates IAM user with minimal permissions:
- `ec2:RunInstances`, `ec2:TerminateInstances`, `ec2:DescribeInstances`
- `ssm:SendCommand`, `ssm:GetCommandInvocation`
- `dynamodb:PutItem`, `dynamodb:GetItem`, `dynamodb:UpdateItem`, `dynamodb:Query`
- `sqs:SendMessage`, `sqs:ReceiveMessage`, `sqs:DeleteMessage`
- Scoped to specific resources where possible

**scripts/setup-cloudflare-token.sh** - Creates API token with:
- `Access: Organizations, Identity Providers, and Groups: Edit`
- `Access: Apps and Policies: Edit`
- `Cloudflare Tunnel: Edit`
- Account-scoped (not zone-scoped since no custom domain)

**scripts/setup-github-app.sh** - Prints instructions to create GitHub App with:
- Permissions: `pull_requests:write`, `statuses:write`, `contents:read`
- Webhook events: `pull_request`
- Generates webhook secret

## Makefile Commands

```makefile
# Setup
make setup              # Run all setup scripts, create .env from .env.example

# Infrastructure
make tf-init            # terraform init for AWS + Cloudflare
make tf-plan            # terraform plan
make tf-apply           # terraform apply
make tf-destroy         # terraform destroy

# AMI
make ami-build          # packer build environment AMI

# Cloudflare Worker
make worker-dev         # wrangler dev (local testing)
make worker-deploy      # wrangler deploy

# Lambda
make lambda-package     # zip Lambda functions
make lambda-deploy      # upload to S3, update Lambda

# All-in-one
make deploy             # tf-apply + ami-build + worker-deploy + lambda-deploy
make destroy            # Full teardown
```
