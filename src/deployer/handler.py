"""
Ephemeral Environments - Deploy Worker Lambda

Handles messages from SQS to deploy or destroy environments.
"""

import json
import os
import time
import logging
from datetime import datetime, timezone

import boto3
from github import Github, GithubIntegration

from ec2_manager import EC2Manager
from cloudflare_api import CloudflareManager
from ssm_commands import SSMCommands

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

# AWS clients
dynamodb = boto3.resource('dynamodb')
secrets_client = boto3.client('secretsmanager')
environments_table = dynamodb.Table(ENVIRONMENTS_TABLE)
builds_table = dynamodb.Table(BUILDS_TABLE)


def get_secret(secret_arn: str) -> dict:
    """Get secret from Secrets Manager."""
    response = secrets_client.get_secret_value(SecretId=secret_arn)
    return json.loads(response['SecretString'])


def get_github_client(repo_full_name: str) -> Github:
    """Get authenticated GitHub client using GitHub App."""
    secrets = get_secret(GITHUB_SECRET_ARN)
    app_id = secrets['app_id']
    private_key = secrets['private_key']

    integration = GithubIntegration(app_id, private_key)

    # Get installation for the repo
    owner = repo_full_name.split('/')[0]
    installation = integration.get_installation(owner, repo_full_name.split('/')[1])
    access_token = integration.get_access_token(installation.id).token

    return Github(access_token)


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
    cf_secrets = get_secret(CLOUDFLARE_SECRET_ARN)
    ec2_manager = EC2Manager(LAUNCH_TEMPLATE_ID, SUBNET_IDS, SECURITY_GROUP_ID)
    cf_manager = CloudflareManager(cf_secrets['api_token'], cf_secrets['account_id'])
    ssm = SSMCommands()

    try:
        # Update GitHub status to pending
        gh = get_github_client(repo)
        gh_repo = gh.get_repo(repo)
        commit = gh_repo.get_commit(sha)
        commit.create_status(
            state='pending',
            description='Deploying environment...',
            context='Ephemeral Environment'
        )

        # If existing environment, stop old instance first
        if existing and existing.get('ec2_instance_id'):
            logger.info(f"Stopping existing instance: {existing['ec2_instance_id']}")
            ec2_manager.terminate_instance(existing['ec2_instance_id'])
            if existing.get('tunnel_id'):
                cf_manager.delete_tunnel(existing['tunnel_id'])

        # Launch new EC2 instance
        instance_id = ec2_manager.launch_instance(
            name=f"ephemeral-{repo.replace('/', '-')}-{pr_number}",
            tags={
                'Repository': repo,
                'PRNumber': str(pr_number),
                'Branch': branch,
            }
        )
        logger.info(f"Launched instance: {instance_id}")

        # Wait for instance to be ready
        ec2_manager.wait_for_instance(instance_id)
        logger.info(f"Instance {instance_id} is ready")

        # Create Cloudflare tunnel
        tunnel_name = f"ephemeral-{repo.replace('/', '-')}-{pr_number}"
        tunnel_id, tunnel_token = cf_manager.create_tunnel(tunnel_name)
        tunnel_url = f"https://{tunnel_id}.cfargotunnel.com"
        logger.info(f"Created tunnel: {tunnel_url}")

        # Run start script via SSM
        ssm.run_start_environment(
            instance_id=instance_id,
            repo_url=clone_url,
            branch=branch,
            tunnel_token=tunnel_token
        )
        logger.info(f"Started environment on {instance_id}")

        # Create Access application for the tunnel
        cf_manager.create_access_application(
            tunnel_id=tunnel_id,
            name=tunnel_name,
            allowed_emails=[message['pullRequest']['author'] + '@users.noreply.github.com']
        )

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

        # Post comment to PR
        pr = gh_repo.get_pull(pr_number)
        comment_body = f"""🚀 **Ephemeral Environment Deployed**

**URL:** {tunnel_url}

_Commit: {sha[:8]}_
"""
        pr.create_issue_comment(comment_body)

        logger.info(f"Environment deployed: {tunnel_url}")

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

    # Get managers
    cf_secrets = get_secret(CLOUDFLARE_SECRET_ARN)
    ec2_manager = EC2Manager(LAUNCH_TEMPLATE_ID, SUBNET_IDS, SECURITY_GROUP_ID)
    cf_manager = CloudflareManager(cf_secrets['api_token'], cf_secrets['account_id'])

    try:
        # Terminate EC2 instance
        if existing.get('ec2_instance_id'):
            logger.info(f"Terminating instance: {existing['ec2_instance_id']}")
            ec2_manager.terminate_instance(existing['ec2_instance_id'])

        # Delete Cloudflare tunnel
        if existing.get('tunnel_id'):
            logger.info(f"Deleting tunnel: {existing['tunnel_id']}")
            cf_manager.delete_tunnel(existing['tunnel_id'])
            cf_manager.delete_access_application(existing['tunnel_id'])

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
