"""
Ephemeral Environments - PR Reconciler Lambda

Runs on a schedule (every 30 minutes) to ensure only EC2 instances
associated with open PRs are running. Provides defense-in-depth against
orphaned resources.

Reconciliation:
1. Find orphaned EC2 instances (tagged as ephemeral but PR is closed)
2. Fix stale DynamoDB records (status=running but EC2 doesn't exist)
"""

from __future__ import annotations

import json
import os
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from functools import cached_property

import boto3
from github import Github, GithubIntegration, GithubException

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ENVIRONMENTS_TABLE = os.environ['ENVIRONMENTS_TABLE']
GITHUB_SECRET_ARN = os.environ['GITHUB_SECRET_ARN']


@dataclass
class ReconciliationStats:
    orphaned_ec2_terminated: int = 0
    stale_dynamo_fixed: int = 0
    prs_checked: int = 0
    errors: list[str] = field(default_factory=list)


@dataclass
class EC2Instance:
    instance_id: str
    repository: str | None
    pr_number: int | None
    state: str


class PRReconcilerService:
    """
    Service for reconciling ephemeral environment state with GitHub PR status.

    Uses lazy initialization for AWS clients to avoid side effects in constructor.
    """

    def __init__(self, environments_table_name: str, github_secret_arn: str):
        self._environments_table_name = environments_table_name
        self._github_secret_arn = github_secret_arn

    @cached_property
    def _dynamodb(self) -> boto3.resources.factory.dynamodb.ServiceResource:
        return boto3.resource('dynamodb')

    @cached_property
    def _environments_table(self):
        return self._dynamodb.Table(self._environments_table_name)

    @cached_property
    def _ec2(self) -> boto3.client:
        return boto3.client('ec2')

    @cached_property
    def _secrets_client(self) -> boto3.client:
        return boto3.client('secretsmanager')

    @cached_property
    def _github_credentials(self) -> dict:
        response = self._secrets_client.get_secret_value(SecretId=self._github_secret_arn)
        return json.loads(response['SecretString'])

    def _get_github_client(self, repo_full_name: str) -> Github:
        """Get authenticated GitHub client for a repository."""
        app_id = self._github_credentials['app_id']
        private_key = self._github_credentials['private_key']

        integration = GithubIntegration(app_id, private_key)
        owner = repo_full_name.split('/')[0]
        repo_name = repo_full_name.split('/')[1]
        installation = integration.get_installation(owner, repo_name)
        access_token = integration.get_access_token(installation.id).token

        return Github(access_token)

    def reconcile(self) -> ReconciliationStats:
        """Run full reconciliation and return stats."""
        stats = ReconciliationStats()

        # Phase 1: Find and terminate orphaned EC2 instances
        self._reconcile_orphaned_ec2(stats)

        # Phase 2: Fix stale DynamoDB records
        self._reconcile_stale_dynamo(stats)

        return stats

    def _reconcile_orphaned_ec2(self, stats: ReconciliationStats) -> None:
        """Find EC2 instances where the PR is no longer open."""
        instances = self._get_ephemeral_ec2_instances()
        logger.info(f"Found {len(instances)} ephemeral EC2 instances to check")

        for instance in instances:
            if not instance.repository or not instance.pr_number:
                logger.warning(f"Instance {instance.instance_id} missing tags, skipping")
                continue

            try:
                pr_is_open = self._check_pr_status(instance.repository, instance.pr_number)
                stats.prs_checked += 1

                if not pr_is_open:
                    logger.info(
                        f"PR {instance.repository}#{instance.pr_number} is closed, "
                        f"terminating instance {instance.instance_id}"
                    )
                    self._terminate_orphaned_instance(instance)
                    stats.orphaned_ec2_terminated += 1

            except GithubException as e:
                error_msg = f"GitHub error checking {instance.repository}#{instance.pr_number}: {e}"
                logger.error(error_msg)
                stats.errors.append(error_msg)
            except Exception as e:
                error_msg = f"Error processing instance {instance.instance_id}: {e}"
                logger.error(error_msg)
                stats.errors.append(error_msg)

    def _reconcile_stale_dynamo(self, stats: ReconciliationStats) -> None:
        """Find DynamoDB records marked running but EC2 doesn't exist."""
        try:
            response = self._environments_table.query(
                IndexName='status-index',
                KeyConditionExpression='#status = :status',
                ExpressionAttributeNames={'#status': 'status'},
                ExpressionAttributeValues={':status': 'running'}
            )
            running_envs = response.get('Items', [])
        except Exception as e:
            error_msg = f"Failed to query DynamoDB: {e}"
            logger.error(error_msg)
            stats.errors.append(error_msg)
            return

        logger.info(f"Found {len(running_envs)} environments marked as running in DynamoDB")

        for env in running_envs:
            pk = env['pk']
            instance_id = env.get('ec2_instance_id')

            if not instance_id:
                continue

            try:
                if not self._instance_exists(instance_id):
                    logger.info(f"Instance {instance_id} no longer exists, fixing DynamoDB record {pk}")
                    self._fix_stale_dynamo_record(pk)
                    stats.stale_dynamo_fixed += 1

            except Exception as e:
                error_msg = f"Error checking instance {instance_id} for {pk}: {e}"
                logger.error(error_msg)
                stats.errors.append(error_msg)

    def _get_ephemeral_ec2_instances(self) -> list[EC2Instance]:
        """Get all EC2 instances tagged as ephemeral environments."""
        response = self._ec2.describe_instances(
            Filters=[
                {'Name': 'tag-key', 'Values': ['Repository']},
                {'Name': 'tag-key', 'Values': ['PRNumber']},
                {'Name': 'instance-state-name', 'Values': ['running', 'stopped', 'pending']}
            ]
        )

        instances = []
        for reservation in response.get('Reservations', []):
            for instance in reservation.get('Instances', []):
                tags = {t['Key']: t['Value'] for t in instance.get('Tags', [])}
                pr_number_str = tags.get('PRNumber')

                instances.append(EC2Instance(
                    instance_id=instance['InstanceId'],
                    repository=tags.get('Repository'),
                    pr_number=int(pr_number_str) if pr_number_str else None,
                    state=instance['State']['Name']
                ))

        return instances

    def _check_pr_status(self, repo: str, pr_number: int) -> bool:
        """Check if a PR is open. Returns True if open, False if closed/merged."""
        gh = self._get_github_client(repo)
        pr = gh.get_repo(repo).get_pull(pr_number)
        return pr.state == 'open'

    def _instance_exists(self, instance_id: str) -> bool:
        """Check if an EC2 instance exists and is not terminated."""
        try:
            response = self._ec2.describe_instances(InstanceIds=[instance_id])
            for reservation in response.get('Reservations', []):
                for instance in reservation.get('Instances', []):
                    state = instance['State']['Name']
                    return state not in ('terminated', 'shutting-down')
            return False
        except self._ec2.exceptions.ClientError as e:
            if 'InvalidInstanceID.NotFound' in str(e):
                return False
            raise

    def _terminate_orphaned_instance(self, instance: EC2Instance) -> None:
        """Terminate an orphaned EC2 instance and update DynamoDB."""
        self._ec2.terminate_instances(InstanceIds=[instance.instance_id])
        logger.info(f"Terminated EC2 instance: {instance.instance_id}")

        if instance.repository and instance.pr_number:
            pk = f"{instance.repository}#{instance.pr_number}"
            self._update_environment_status(pk, 'terminated')

    def _fix_stale_dynamo_record(self, pk: str) -> None:
        """Update a stale DynamoDB record to terminated status."""
        self._update_environment_status(pk, 'terminated')

    def _update_environment_status(self, pk: str, status: str) -> None:
        """Update environment status in DynamoDB."""
        self._environments_table.update_item(
            Key={'pk': pk},
            UpdateExpression='SET #status = :status, updated_at = :now',
            ExpressionAttributeNames={'#status': 'status'},
            ExpressionAttributeValues={
                ':status': status,
                ':now': datetime.now(timezone.utc).isoformat(),
            }
        )
        logger.info(f"Updated DynamoDB record {pk} to status: {status}")


def lambda_handler(event, context):
    """Main Lambda handler - runs PR reconciliation."""
    logger.info("Starting PR reconciliation run")

    service = PRReconcilerService(
        environments_table_name=ENVIRONMENTS_TABLE,
        github_secret_arn=GITHUB_SECRET_ARN
    )

    stats = service.reconcile()

    logger.info(
        f"Reconciliation complete: "
        f"orphaned_ec2_terminated={stats.orphaned_ec2_terminated}, "
        f"stale_dynamo_fixed={stats.stale_dynamo_fixed}, "
        f"prs_checked={stats.prs_checked}, "
        f"errors={len(stats.errors)}"
    )

    return {
        'statusCode': 200,
        'stats': {
            'orphaned_ec2_terminated': stats.orphaned_ec2_terminated,
            'stale_dynamo_fixed': stats.stale_dynamo_fixed,
            'prs_checked': stats.prs_checked,
            'errors': stats.errors,
        }
    }
