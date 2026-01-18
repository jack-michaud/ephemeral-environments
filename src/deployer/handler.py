"""
Ephemeral Environments - Deploy Worker Lambda

Handles messages from SQS to deploy or destroy environments.
"""

import json
import os
import time
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from contextlib import contextmanager
from typing import Optional

import boto3
from github import Github, GithubIntegration

from ec2_manager import EC2Manager
from cloudflare_api import CloudflareManager
from ssm_commands import SSMCommands


@contextmanager
def timed_step(name: str, timings: dict):
    """Context manager to track timing of a step."""
    start = time.time()
    logger.info(f"[TIMING] Starting: {name}")
    try:
        yield
    finally:
        elapsed = time.time() - start
        timings[name] = elapsed
        logger.info(f"[TIMING] Completed: {name} in {elapsed:.2f}s")

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment variables
ENVIRONMENTS_TABLE = os.environ['ENVIRONMENTS_TABLE']
BUILDS_TABLE = os.environ['BUILDS_TABLE']
LAUNCH_TEMPLATE_ID = os.environ['LAUNCH_TEMPLATE_ID']
SUBNET_IDS = os.environ['SUBNET_IDS'].split(',')
SECURITY_GROUP_ID = os.environ['SECURITY_GROUP_ID']
GITHUB_SECRET_ARN = os.environ['GITHUB_SECRET_ARN']
CLOUDFLARE_SECRET_ARN = os.environ['CLOUDFLARE_SECRET_ARN']
REPO_SECRETS_PREFIX = os.environ.get('REPO_SECRETS_PREFIX', 'ephemeral-env/repos')

# AWS clients
dynamodb = boto3.resource('dynamodb')
secrets_client = boto3.client('secretsmanager')
ssm_client = boto3.client('ssm')
environments_table = dynamodb.Table(ENVIRONMENTS_TABLE)
builds_table = dynamodb.Table(BUILDS_TABLE)


def get_secret(secret_arn: str) -> dict:
    """Get secret from Secrets Manager."""
    response = secrets_client.get_secret_value(SecretId=secret_arn)
    return json.loads(response['SecretString'])


def get_github_token(repo_full_name: str) -> str:
    """Get GitHub App installation access token for a repository."""
    secrets = get_secret(GITHUB_SECRET_ARN)
    app_id = secrets['app_id']
    private_key = secrets['private_key']

    integration = GithubIntegration(app_id, private_key)

    # Get installation for the repo
    owner = repo_full_name.split('/')[0]
    installation = integration.get_installation(owner, repo_full_name.split('/')[1])
    access_token = integration.get_access_token(installation.id).token

    return access_token


def get_github_client(repo_full_name: str) -> Github:
    """Get authenticated GitHub client using GitHub App."""
    return Github(get_github_token(repo_full_name))


@dataclass
class RepoConfig:
    """Configuration for a repository's ephemeral environment."""
    instance_profile_arn: Optional[str] = None
    secrets: dict = field(default_factory=dict)

    @classmethod
    def from_secret(cls, secret_string: str) -> 'RepoConfig':
        """Parse RepoConfig from Secrets Manager JSON."""
        data = json.loads(secret_string)
        return cls(
            instance_profile_arn=data.get('instance_profile_arn'),
            secrets=data.get('secrets', {})
        )

    @classmethod
    def empty(cls) -> 'RepoConfig':
        """Return an empty config for repos without configuration."""
        return cls()


def get_repo_config(repo_full_name: str) -> RepoConfig:
    """
    Fetch repository configuration including instance profile ARN.

    The EC2 instance will use the per-repo instance profile to fetch its own
    secrets via IAM role, so we don't need to fetch secrets here anymore.

    Returns RepoConfig with instance_profile_arn (secrets are fetched by instance).
    """
    secret_name = f"{REPO_SECRETS_PREFIX}/{repo_full_name}"

    try:
        response = secrets_client.get_secret_value(SecretId=secret_name)
        config = RepoConfig.from_secret(response['SecretString'])
        logger.info(f"Loaded config for {repo_full_name}: instance_profile={bool(config.instance_profile_arn)}")
        return config
    except secrets_client.exceptions.ResourceNotFoundException:
        logger.info(f"No config for {repo_full_name}, using default instance profile")
        return RepoConfig.empty()


def lambda_handler(event, context):
    """Main Lambda handler - processes SQS messages."""
    logger.info(f"Received event: {json.dumps(event)}")

    for record in event.get('Records', []):
        try:
            message = json.loads(record['body'])
            action = message.get('action')

            if action == 'deploy':
                handle_deploy(message)
            elif action == 'destroy':
                handle_destroy(message)
            else:
                logger.warning(f"Unknown action: {action}")

        except Exception as e:
            logger.exception(f"Error processing message: {e}")
            raise  # Re-raise to trigger DLQ

    return {'statusCode': 200}


def handle_deploy(message: dict):
    """Handle deploy action - spin up environment."""
    deploy_start = time.time()
    timings = {}

    repo = message['repository']['fullName']
    pr_number = message['pullRequest']['number']
    branch = message['pullRequest']['branch']
    sha = message['pullRequest']['sha']
    clone_url = message['repository']['cloneUrl']
    pr_url = message['pullRequest']['url']

    pk = f"{repo}#{pr_number}"
    build_id = f"build-{sha[:8]}-{int(time.time())}"

    logger.info(f"Deploying environment for {pk}")

    # Check if environment already exists
    existing = environments_table.get_item(Key={'pk': pk}).get('Item')

    # Get managers
    with timed_step("get_secrets", timings):
        cf_secrets = get_secret(CLOUDFLARE_SECRET_ARN)
    ec2_manager = EC2Manager(LAUNCH_TEMPLATE_ID, SUBNET_IDS, SECURITY_GROUP_ID)
    cf_manager = CloudflareManager(
        cf_secrets['api_token'],
        cf_secrets['account_id'],
        zone_id=cf_secrets.get('zone_id'),
        domain=cf_secrets.get('domain')
    )
    ssm = SSMCommands()

    try:
        # Get GitHub token for repo cloning and API access
        with timed_step("get_github_token", timings):
            github_token = get_github_token(repo)
            gh = Github(github_token)
            gh_repo = gh.get_repo(repo)
            commit = gh_repo.get_commit(sha)
            commit.create_status(
                state='pending',
                description='Deploying environment...',
                context='Ephemeral Environment'
            )

        # Get repo-specific configuration (instance profile for IAM-based secrets)
        with timed_step("get_repo_config", timings):
            repo_config = get_repo_config(repo)

        # If existing environment, stop old instance first
        if existing and existing.get('ec2_instance_id'):
            with timed_step("terminate_old_instance", timings):
                logger.info(f"Stopping existing instance: {existing['ec2_instance_id']}")
                ec2_manager.terminate_instance(existing['ec2_instance_id'])
                if existing.get('tunnel_id'):
                    cf_manager.delete_tunnel(existing['tunnel_id'])

        # Launch new EC2 instance (with per-repo IAM profile if configured)
        with timed_step("launch_instance", timings):
            instance_id = ec2_manager.launch_instance(
                name=f"ephemeral-{repo.replace('/', '-')}-{pr_number}",
                tags={
                    'Repository': repo,
                    'PRNumber': str(pr_number),
                    'Branch': branch,
                },
                instance_profile_arn=repo_config.instance_profile_arn
            )
        logger.info(f"Launched instance: {instance_id}")

        # Wait for instance to be ready
        with timed_step("wait_for_instance", timings):
            ec2_manager.wait_for_instance(instance_id)
        logger.info(f"Instance {instance_id} is ready")

        # Run start script via SSM - this starts docker-compose and Quick Tunnel
        # The Quick Tunnel URL is captured from cloudflared output
        # Note: Secrets are fetched by the instance via IAM role (not embedded in SSM)
        with timed_step("run_ssm_start_environment", timings):
            result = ssm.run_start_environment(
                instance_id=instance_id,
                repo_url=clone_url,
                branch=branch,
                github_token=github_token
            )
        logger.info(f"Started environment on {instance_id}")

        # Extract tunnel URL from SSM output
        import re
        tunnel_url = None
        tunnel_id = None
        stdout = result.get('stdout', '')
        url_match = re.search(r'TUNNEL_URL=(https://[a-zA-Z0-9-]+\.trycloudflare\.com)', stdout)
        if url_match:
            tunnel_url = url_match.group(1)
            # Extract ID from URL for reference
            tunnel_id = tunnel_url.replace('https://', '').replace('.trycloudflare.com', '')
            logger.info(f"Quick Tunnel URL: {tunnel_url}")
        else:
            logger.error(f"Could not extract tunnel URL from output: {stdout}")
            raise Exception("Quick Tunnel URL not found in SSM output")

        # Save to DynamoDB
        now = datetime.now(timezone.utc).isoformat()
        environments_table.put_item(Item={
            'pk': pk,
            'repository': repo,
            'pr_number': pr_number,
            'branch': branch,
            'sha': sha,
            'status': 'running',
            'ec2_instance_id': instance_id,
            'tunnel_id': tunnel_id,
            'tunnel_url': tunnel_url,
            'created_at': now,
            'updated_at': now,
            'last_activity': now,
        })

        builds_table.put_item(Item={
            'environment_id': pk,
            'build_id': build_id,
            'sha': sha,
            'status': 'success',
            'created_at': now,
        })

        # Update GitHub status to success
        commit.create_status(
            state='success',
            target_url=tunnel_url,
            description='Environment ready!',
            context='Ephemeral Environment'
        )

        # Calculate total deploy time
        total_time = time.time() - deploy_start
        timings['total'] = total_time

        # Log timing summary
        logger.info(f"[TIMING] === Deploy Summary for {pk} ===")
        for step, duration in sorted(timings.items(), key=lambda x: x[1], reverse=True):
            logger.info(f"[TIMING]   {step}: {duration:.2f}s")

        # Post comment to PR with timing info
        pr = gh_repo.get_pull(pr_number)
        timing_breakdown = " | ".join([f"{k}: {v:.0f}s" for k, v in timings.items() if k != 'total'])
        comment_body = f"""🚀 **Ephemeral Environment Deployed**

**URL:** {tunnel_url}

_Commit: {sha[:8]} | Deploy time: {total_time:.0f}s_

<details>
<summary>Timing breakdown</summary>

{timing_breakdown}
</details>
"""
        pr.create_issue_comment(comment_body)

        logger.info(f"Environment deployed: {tunnel_url} in {total_time:.0f}s")

    except Exception as e:
        logger.exception(f"Failed to deploy environment: {e}")

        # Update GitHub status to failure
        try:
            commit.create_status(
                state='failure',
                description=f'Deployment failed: {str(e)[:100]}',
                context='Ephemeral Environment'
            )
        except:
            pass

        # Update DynamoDB
        environments_table.update_item(
            Key={'pk': pk},
            UpdateExpression='SET #status = :status, error_message = :error, updated_at = :now',
            ExpressionAttributeNames={'#status': 'status'},
            ExpressionAttributeValues={
                ':status': 'failed',
                ':error': str(e),
                ':now': datetime.now(timezone.utc).isoformat(),
            }
        )

        raise


def handle_destroy(message: dict):
    """Handle destroy action - tear down environment."""
    repo = message['repository']['fullName']
    pr_number = message['pullRequest']['number']
    pk = f"{repo}#{pr_number}"

    logger.info(f"Destroying environment for {pk}")

    # Get existing environment
    existing = environments_table.get_item(Key={'pk': pk}).get('Item')
    if not existing:
        logger.info(f"No environment found for {pk}")
        return

    # Get EC2 manager
    ec2_manager = EC2Manager(LAUNCH_TEMPLATE_ID, SUBNET_IDS, SECURITY_GROUP_ID)

    try:
        # Terminate EC2 instance (this also kills the Quick Tunnel)
        if existing.get('ec2_instance_id'):
            logger.info(f"Terminating instance: {existing['ec2_instance_id']}")
            ec2_manager.terminate_instance(existing['ec2_instance_id'])

        # Update DynamoDB
        environments_table.update_item(
            Key={'pk': pk},
            UpdateExpression='SET #status = :status, updated_at = :now',
            ExpressionAttributeNames={'#status': 'status'},
            ExpressionAttributeValues={
                ':status': 'destroyed',
                ':now': datetime.now(timezone.utc).isoformat(),
            }
        )

        logger.info(f"Environment destroyed for {pk}")

    except Exception as e:
        logger.exception(f"Failed to destroy environment: {e}")
        raise
