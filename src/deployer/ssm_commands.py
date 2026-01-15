"""
SSM Commands - Run commands on EC2 instances via AWS Systems Manager.
"""

import time
import logging
import boto3

logger = logging.getLogger(__name__)


class SSMCommands:
    def __init__(self):
        self.ssm = boto3.client('ssm')

    def run_command(
        self,
        instance_id: str,
        commands: list,
        timeout: int = 600
    ) -> dict:
        """
        Run shell commands on an EC2 instance via SSM.

        Args:
            instance_id: EC2 instance ID
            commands: List of shell commands to run
            timeout: Timeout in seconds

        Returns:
            Command output dict with stdout and stderr
        """
        response = self.ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName='AWS-RunShellScript',
            Parameters={'commands': commands},
            TimeoutSeconds=timeout,
        )

        command_id = response['Command']['CommandId']
        logger.info(f"Sent SSM command {command_id} to {instance_id}")

        # Wait for command to complete
        return self._wait_for_command(instance_id, command_id, timeout)

    def _wait_for_command(
        self,
        instance_id: str,
        command_id: str,
        timeout: int
    ) -> dict:
        """Wait for SSM command to complete and return output."""
        start_time = time.time()

        while time.time() - start_time < timeout:
            try:
                result = self.ssm.get_command_invocation(
                    CommandId=command_id,
                    InstanceId=instance_id,
                )

                status = result['Status']

                if status == 'Success':
                    logger.info(f"Command {command_id} succeeded")
                    return {
                        'status': 'success',
                        'stdout': result.get('StandardOutputContent', ''),
                        'stderr': result.get('StandardErrorContent', ''),
                    }
                elif status in ['Failed', 'Cancelled', 'TimedOut']:
                    error_msg = result.get('StandardErrorContent', 'Unknown error')
                    logger.error(f"Command {command_id} failed: {error_msg}")
                    raise Exception(f"SSM command failed: {error_msg}")
                elif status in ['Pending', 'InProgress', 'Delayed']:
                    time.sleep(5)
                else:
                    logger.warning(f"Unknown command status: {status}")
                    time.sleep(5)

            except self.ssm.exceptions.InvocationDoesNotExist:
                # Command not yet available
                time.sleep(5)

        raise Exception(f"Command {command_id} timed out after {timeout}s")

    def run_start_environment(
        self,
        instance_id: str,
        repo_url: str,
        branch: str,
        tunnel_token: str
    ):
        """
        Run the start-environment script on an instance.

        This clones the repo, runs docker-compose, and starts cloudflared.
        """
        commands = [
            f'/usr/local/bin/start-environment.sh "{repo_url}" "{branch}" "{tunnel_token}"'
        ]

        return self.run_command(instance_id, commands, timeout=900)

    def run_rebuild_environment(self, instance_id: str, branch: str):
        """
        Rebuild an existing environment after a code push.
        """
        commands = [
            'cd /app/repo',
            f'git fetch origin {branch}',
            f'git reset --hard origin/{branch}',
            'docker compose up -d --build',
        ]

        return self.run_command(instance_id, commands, timeout=600)

    def get_docker_logs(self, instance_id: str, service: str = None) -> str:
        """Get Docker logs from the instance."""
        if service:
            commands = [f'cd /app/repo && docker compose logs --tail=100 {service}']
        else:
            commands = ['cd /app/repo && docker compose logs --tail=100']

        result = self.run_command(instance_id, commands, timeout=60)
        return result.get('stdout', '')
