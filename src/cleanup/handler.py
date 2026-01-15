"""
Ephemeral Environments - Cleanup Worker Lambda

Runs on a schedule to:
1. Stop idle environments (after AUTO_STOP_HOURS)
2. Terminate stopped environments (after 24h)
3. Clean up orphaned resources
"""

import json
import os
import logging
from datetime import datetime, timezone, timedelta

import boto3
import requests

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment variables
ENVIRONMENTS_TABLE = os.environ['ENVIRONMENTS_TABLE']
AUTO_STOP_HOURS = int(os.environ.get('AUTO_STOP_HOURS', '4'))
CLOUDFLARE_SECRET_ARN = os.environ['CLOUDFLARE_SECRET_ARN']

# AWS clients
dynamodb = boto3.resource('dynamodb')
ec2 = boto3.client('ec2')
secrets_client = boto3.client('secretsmanager')
environments_table = dynamodb.Table(ENVIRONMENTS_TABLE)

# Cloudflare API
CF_API_BASE = "https://api.cloudflare.com/client/v4"


def get_cloudflare_credentials() -> tuple:
    """Get Cloudflare credentials from Secrets Manager."""
    response = secrets_client.get_secret_value(SecretId=CLOUDFLARE_SECRET_ARN)
    secrets = json.loads(response['SecretString'])
    return secrets['api_token'], secrets['account_id']


def lambda_handler(event, context):
    """Main Lambda handler - runs cleanup tasks."""
    logger.info("Starting cleanup run")

    now = datetime.now(timezone.utc)
    auto_stop_threshold = now - timedelta(hours=AUTO_STOP_HOURS)
    terminate_threshold = now - timedelta(hours=24)

    stats = {
        'stopped': 0,
        'terminated': 0,
        'errors': 0,
    }

    # Get all running environments
    try:
        response = environments_table.query(
            IndexName='status-index',
            KeyConditionExpression='#status = :status',
            ExpressionAttributeNames={'#status': 'status'},
            ExpressionAttributeValues={':status': 'running'}
        )
        running_envs = response.get('Items', [])
    except Exception as e:
        logger.error(f"Failed to query environments: {e}")
        running_envs = []

    # Check each running environment
    for env in running_envs:
        pk = env['pk']
        instance_id = env.get('ec2_instance_id')
        last_activity = env.get('last_activity', env.get('created_at'))

        if not instance_id:
            continue

        try:
            last_activity_dt = datetime.fromisoformat(last_activity.replace('Z', '+00:00'))

            # Check if idle too long
            if last_activity_dt < auto_stop_threshold:
                logger.info(f"Stopping idle environment: {pk}")
                stop_environment(env)
                stats['stopped'] += 1

        except Exception as e:
            logger.error(f"Error processing {pk}: {e}")
            stats['errors'] += 1

    # Get all stopped environments
    try:
        response = environments_table.query(
            IndexName='status-index',
            KeyConditionExpression='#status = :status',
            ExpressionAttributeNames={'#status': 'status'},
            ExpressionAttributeValues={':status': 'stopped'}
        )
        stopped_envs = response.get('Items', [])
    except Exception as e:
        logger.error(f"Failed to query stopped environments: {e}")
        stopped_envs = []

    # Terminate old stopped environments
    for env in stopped_envs:
        pk = env['pk']
        updated_at = env.get('updated_at', env.get('created_at'))

        try:
            updated_at_dt = datetime.fromisoformat(updated_at.replace('Z', '+00:00'))

            if updated_at_dt < terminate_threshold:
                logger.info(f"Terminating old environment: {pk}")
                terminate_environment(env)
                stats['terminated'] += 1

        except Exception as e:
            logger.error(f"Error terminating {pk}: {e}")
            stats['errors'] += 1

    logger.info(f"Cleanup complete: {stats}")
    return {'statusCode': 200, 'stats': stats}


def stop_environment(env: dict):
    """Stop an environment (stop EC2, keep tunnel for quick restart)."""
    pk = env['pk']
    instance_id = env.get('ec2_instance_id')

    if instance_id:
        try:
            ec2.stop_instances(InstanceIds=[instance_id])
            logger.info(f"Stopped EC2 instance: {instance_id}")
        except Exception as e:
            logger.error(f"Failed to stop instance {instance_id}: {e}")

    # Update status in DynamoDB
    environments_table.update_item(
        Key={'pk': pk},
        UpdateExpression='SET #status = :status, updated_at = :now',
        ExpressionAttributeNames={'#status': 'status'},
        ExpressionAttributeValues={
            ':status': 'stopped',
            ':now': datetime.now(timezone.utc).isoformat(),
        }
    )


def terminate_environment(env: dict):
    """Fully terminate an environment (EC2 + tunnel + cleanup)."""
    pk = env['pk']
    instance_id = env.get('ec2_instance_id')
    tunnel_id = env.get('tunnel_id')

    # Terminate EC2 instance
    if instance_id:
        try:
            ec2.terminate_instances(InstanceIds=[instance_id])
            logger.info(f"Terminated EC2 instance: {instance_id}")
        except Exception as e:
            logger.error(f"Failed to terminate instance {instance_id}: {e}")

    # Delete Cloudflare tunnel
    if tunnel_id:
        try:
            delete_cloudflare_tunnel(tunnel_id)
            logger.info(f"Deleted tunnel: {tunnel_id}")
        except Exception as e:
            logger.error(f"Failed to delete tunnel {tunnel_id}: {e}")

    # Update status in DynamoDB
    environments_table.update_item(
        Key={'pk': pk},
        UpdateExpression='SET #status = :status, updated_at = :now',
        ExpressionAttributeNames={'#status': 'status'},
        ExpressionAttributeValues={
            ':status': 'terminated',
            ':now': datetime.now(timezone.utc).isoformat(),
        }
    )


def delete_cloudflare_tunnel(tunnel_id: str):
    """Delete a Cloudflare tunnel and its Access application."""
    api_token, account_id = get_cloudflare_credentials()
    headers = {
        "Authorization": f"Bearer {api_token}",
        "Content-Type": "application/json"
    }

    # Delete tunnel connections first
    try:
        requests.delete(
            f"{CF_API_BASE}/accounts/{account_id}/cfd_tunnel/{tunnel_id}/connections",
            headers=headers
        )
    except Exception:
        pass

    # Delete tunnel
    requests.delete(
        f"{CF_API_BASE}/accounts/{account_id}/cfd_tunnel/{tunnel_id}",
        headers=headers
    )

    # Find and delete Access application
    try:
        response = requests.get(
            f"{CF_API_BASE}/accounts/{account_id}/access/apps",
            headers=headers
        )
        if response.ok:
            apps = response.json().get('result', [])
            domain = f"{tunnel_id}.cfargotunnel.com"
            for app in apps:
                if app.get('domain') == domain:
                    requests.delete(
                        f"{CF_API_BASE}/accounts/{account_id}/access/apps/{app['id']}",
                        headers=headers
                    )
                    break
    except Exception as e:
        logger.warning(f"Failed to delete Access app: {e}")
