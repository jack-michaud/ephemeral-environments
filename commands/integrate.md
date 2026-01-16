---
name: integrate
description: Analyze a project and guide integration with the ephemeral environment system for PR preview deployments
allowed-tools:
  - Read
  - Glob
  - Grep
  - Write
  - Edit
  - AskUserQuestion
argument-hint: "[path-to-project]"
---

# Integrate Project with Ephemeral Environments

Analyze the target project and guide the user through integrating it with the ephemeral environment system for automatic PR preview deployments.

## Invocation

The user runs `/integrate` optionally with a path argument:
- `/integrate` - Analyze current working directory
- `/integrate /path/to/project` - Analyze specified project directory

## Analysis Steps

### Step 1: Locate Project Root

Determine the project root:
- If argument provided, use that path
- Otherwise, use current working directory
- Verify the path exists and is a directory

### Step 2: Check for docker-compose.yml

Search for docker-compose configuration:
1. Look for `docker-compose.yml` or `docker-compose.yaml` in project root
2. Also check for `compose.yml` or `compose.yaml` (Docker Compose v2 naming)

If found:
- Read the file contents
- Proceed to port analysis

If not found:
- Note this for the user
- Proceed to project analysis to determine what services are needed

### Step 3: Analyze Port Configuration

If docker-compose exists, check port mappings:
- Look for `ports:` sections
- Identify if port 80 is exposed externally
- Note any services that expose ports

**Valid configurations:**
```yaml
ports:
  - "80:3000"      # Good - port 80 exposed
  - "80:8080"      # Good - port 80 exposed
```

**Invalid configurations:**
```yaml
ports:
  - "3000:3000"    # Bad - port 80 not exposed
  - "8080:8080"    # Bad - port 80 not exposed
```

### Step 4: Identify Application Type

Analyze the project to determine technology stack:
- Check for `package.json` (Node.js)
- Check for `requirements.txt` or `pyproject.toml` (Python)
- Check for `go.mod` (Go)
- Check for `Gemfile` (Ruby)
- Check for `pom.xml` or `build.gradle` (Java)
- Check for `Cargo.toml` (Rust)

Note the typical port for the detected framework.

### Step 5: Check for Dockerfile

Look for Dockerfile in project root:
- If exists, verify it exposes a port
- Check for EXPOSE directive
- Verify CMD or ENTRYPOINT is defined

### Step 6: Identify Required Services

Look for common dependencies:
- Database connections (PostgreSQL, MySQL, MongoDB)
- Cache services (Redis, Memcached)
- Search services (Elasticsearch)
- Message queues (RabbitMQ, Kafka)

Check in:
- Environment variable references
- Configuration files
- Import statements

## Report Generation

Present findings to the user:

### If docker-compose.yml Exists and Is Compatible

```
## Analysis Complete

Your project appears ready for ephemeral environment integration.

**docker-compose.yml**: Found
**Port 80**: Exposed correctly
**Services**: [list detected services]

### Next Steps

1. Install the ephemeral-environments GitHub App on your repository
2. Open a pull request to test the integration
3. A preview URL will be posted as a PR comment
```

### If docker-compose.yml Exists but Needs Modification

```
## Analysis Complete

Your project has a docker-compose.yml but needs modification for ephemeral environments.

**Issue**: Port 80 is not exposed

### Current Configuration
[show relevant port config]

### Required Change
Update the ports mapping to expose port 80:
[show corrected config]

Would you like me to update the docker-compose.yml?
```

### If docker-compose.yml Does Not Exist

```
## Analysis Complete

Your project needs a docker-compose.yml file for ephemeral environment integration.

**Detected Stack**: [Node.js/Python/Go/etc.]
**Detected Dependencies**: [PostgreSQL/Redis/etc.]

### Recommended docker-compose.yml

[Show recommended configuration based on detected stack]

Would you like me to create this docker-compose.yml?
```

## User Interaction

Use AskUserQuestion when:
- Offering to modify existing docker-compose.yml
- Offering to create new docker-compose.yml
- Clarifying which service should be the main entry point (if multiple candidates)
- Asking about additional services needed

## File Generation

When generating docker-compose.yml:

1. Base on detected application type
2. Use appropriate base images
3. Include detected dependencies as services
4. Configure health checks for databases
5. Set sensible defaults for environment variables

**Template structure:**
```yaml
services:
  app:
    build: .
    ports:
      - "80:[detected-port]"
    environment:
      - NODE_ENV=production  # or equivalent
    depends_on:
      # Add dependencies with health checks

  # Add detected dependencies (db, redis, etc.)
```

## Dockerfile Generation

If no Dockerfile exists, offer to create one:

1. Base on detected application type
2. Use multi-stage builds where appropriate
3. Include security best practices (non-root user)
4. Optimize for layer caching

## Final Checklist

After analysis and any file generation, present:

```
## Integration Checklist

- [ ] docker-compose.yml exists and exposes port 80
- [ ] Dockerfile builds successfully
- [ ] Application runs with `docker-compose up`
- [ ] GitHub App installed on repository

### Test Locally

Run these commands to verify:
docker-compose build
docker-compose up
# Then visit http://localhost in your browser

### Install GitHub App

[Provide link or instructions for GitHub App installation]
```

## Error Handling

If the project cannot be analyzed:
- Explain what was expected
- Suggest manual configuration
- Point to the ephemeral-integration skill for detailed documentation
