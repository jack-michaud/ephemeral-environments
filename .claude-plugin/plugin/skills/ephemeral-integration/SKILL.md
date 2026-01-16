---
name: ephemeral-integration
description: This skill should be used when the user asks to "integrate with ephemeral environments", "set up PR previews", "add preview environments to my repo", "configure ephemeral deployments", "create PR preview environments", or mentions wanting automatic preview URLs for pull requests. Provides guidance for integrating any project with the ephemeral environment system.
---

# Ephemeral Environment Integration

This skill provides guidance for integrating projects with the ephemeral environment system, which automatically creates preview deployments for GitHub pull requests.

## Overview

The ephemeral environment system automatically:
1. Detects when a PR is opened or updated
2. Spins up an EC2 instance with the PR's code
3. Runs the application via docker-compose
4. Exposes it publicly through a Cloudflare tunnel
5. Posts the preview URL as a PR comment
6. Cleans up when the PR closes

## Integration Requirements

To integrate a project, two things are needed:

### 1. Compatible docker-compose.yml

The project must have a `docker-compose.yml` file in the repository root that:
- Exposes the application on **port 80**
- Uses standard Docker Compose syntax
- Contains all services needed to run the application

**Minimal example:**
```yaml
services:
  app:
    build: .
    ports:
      - "80:3000"  # Map internal port to 80
```

**With database:**
```yaml
services:
  app:
    build: .
    ports:
      - "80:8080"
    environment:
      - DATABASE_URL=postgres://postgres:postgres@db:5432/app
    depends_on:
      - db

  db:
    image: postgres:15
    environment:
      - POSTGRES_PASSWORD=postgres
      - POSTGRES_DB=app
```

### 2. GitHub App Installation

The ephemeral-environments GitHub App must be installed on the repository:
1. Navigate to the GitHub App settings page
2. Install on the target repository
3. Grant necessary permissions (repository contents, pull requests, commit statuses)

## Port Configuration

The system expects the application to be accessible on port 80. Common patterns:

| Framework | Internal Port | docker-compose mapping |
|-----------|--------------|------------------------|
| Node/Express | 3000 | `"80:3000"` |
| Python/Flask | 5000 | `"80:5000"` |
| Python/Django | 8000 | `"80:8000"` |
| Go | 8080 | `"80:8080"` |
| Ruby/Rails | 3000 | `"80:3000"` |
| Java/Spring | 8080 | `"80:8080"` |

## docker-compose.yml Patterns

### Single Service Application

For simple applications with just the main service:

```yaml
services:
  app:
    build: .
    ports:
      - "80:3000"
    environment:
      - NODE_ENV=production
```

### Application with Database

For applications requiring a database:

```yaml
services:
  app:
    build: .
    ports:
      - "80:3000"
    environment:
      - DATABASE_URL=postgres://postgres:postgres@db:5432/app
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:15
    environment:
      - POSTGRES_PASSWORD=postgres
      - POSTGRES_DB=app
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5
```

### Application with Redis

For applications using Redis for caching or sessions:

```yaml
services:
  app:
    build: .
    ports:
      - "80:8000"
    environment:
      - REDIS_URL=redis://redis:6379
    depends_on:
      - redis

  redis:
    image: redis:7-alpine
```

### Full Stack Application

For applications with frontend, backend, and database:

```yaml
services:
  frontend:
    build: ./frontend
    ports:
      - "80:80"
    depends_on:
      - backend

  backend:
    build: ./backend
    expose:
      - "8080"
    environment:
      - DATABASE_URL=postgres://postgres:postgres@db:5432/app
    depends_on:
      - db

  db:
    image: postgres:15
    environment:
      - POSTGRES_PASSWORD=postgres
```

## Environment Variables

For sensitive configuration, use environment variables in docker-compose:

```yaml
services:
  app:
    build: .
    ports:
      - "80:3000"
    environment:
      - API_KEY=${API_KEY}
      - SECRET_KEY=${SECRET_KEY}
```

**Note:** Environment variables must be configured in the ephemeral environment system's secrets management to be available during deployment.

## Dockerfile Requirements

Ensure the Dockerfile:
- Builds successfully without external dependencies
- Includes all runtime dependencies
- Exposes the correct port
- Has a proper CMD or ENTRYPOINT

**Example Node.js Dockerfile:**
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
EXPOSE 3000
CMD ["node", "server.js"]
```

**Example Python Dockerfile:**
```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "app:app"]
```

## Verification Checklist

Before opening a PR, verify:

- [ ] `docker-compose.yml` exists in repository root
- [ ] Port 80 is exposed in docker-compose.yml
- [ ] `docker-compose up` runs successfully locally
- [ ] Application is accessible at `http://localhost` after startup
- [ ] GitHub App is installed on the repository
- [ ] All required services (db, redis, etc.) are defined

## How It Works

When a PR is opened:

1. **Webhook**: GitHub sends a webhook to the Cloudflare Worker
2. **Queue**: Worker validates and sends message to AWS SQS
3. **Deploy**: Lambda function launches EC2 instance from AMI
4. **Clone**: Instance clones the PR branch via SSM commands
5. **Start**: docker-compose starts all services
6. **Tunnel**: Cloudflare Quick Tunnel exposes port 80
7. **Notify**: Preview URL posted as PR comment and commit status

When a PR closes:

1. **Webhook**: GitHub sends closed event
2. **Cleanup**: Lambda terminates the EC2 instance
3. **State**: DynamoDB record updated to "destroyed"

Scheduled maintenance ensures orphaned environments are cleaned up.

## Using the /integrate Command

Run the `/integrate` command in this repository for interactive setup assistance. The command will:

1. Check for existing docker-compose.yml
2. Analyze port configuration
3. Validate Dockerfile if present
4. Offer to generate compatible configuration
5. Provide next steps for GitHub App installation

## Common Issues

### Application not accessible

- Verify port 80 is exposed in docker-compose.yml
- Check the internal port matches what the application listens on
- Ensure the application binds to `0.0.0.0`, not `127.0.0.1`

### Container fails to start

- Test locally with `docker-compose up --build`
- Check for missing environment variables
- Verify all dependencies are available

### Preview URL not posted

- Confirm GitHub App is installed
- Check PR is from a branch in the same repository (not a fork)
- Verify webhook is configured correctly
