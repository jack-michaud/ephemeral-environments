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
        timeout: int = 600,
        max_retries: int = 30
    ) -> dict:
        """
        Run shell commands on an EC2 instance via SSM.

        Args:
            instance_id: EC2 instance ID
            commands: List of shell commands to run
            timeout: Timeout in seconds
            max_retries: Max retries for SSM agent not ready

        Returns:
            Command output dict with stdout and stderr
        """
        # Retry send_command until SSM agent is ready
        start_time = time.time()
        for attempt in range(max_retries):
            try:
                response = self.ssm.send_command(
                    InstanceIds=[instance_id],
                    DocumentName='AWS-RunShellScript',
                    Parameters={'commands': commands},
                    TimeoutSeconds=timeout,
                )
                command_id = response['Command']['CommandId']
                logger.info(f"[TIMING] ssm_send_command_ready: {time.time() - start_time:.2f}s (attempt {attempt + 1})")
                logger.info(f"Sent SSM command {command_id} to {instance_id}")

                # Wait for command to complete
                return self._wait_for_command(instance_id, command_id, timeout)

            except self.ssm.exceptions.InvalidInstanceId:
                # Instance not yet registered with SSM
                if attempt < max_retries - 1:
                    time.sleep(1)  # Retry every 1s
                    continue
                raise

        raise Exception(f"Failed to send SSM command after {max_retries} retries")

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
                    time.sleep(1)  # Poll aggressively (1s)
                else:
                    logger.warning(f"Unknown command status: {status}")
                    time.sleep(1)

            except self.ssm.exceptions.InvocationDoesNotExist:
                # Command not yet available
                time.sleep(1)  # Poll faster initially

        raise Exception(f"Command {command_id} timed out after {timeout}s")

    def run_start_environment(
        self,
        instance_id: str,
        repo_url: str,
        branch: str,
        tunnel_token: str = None,
        github_token: str = None
    ):
        """
        Run the start-environment script on an instance.

        This clones the repo, runs docker-compose, and starts cloudflared Quick Tunnel.
        Returns the trycloudflare.com URL in the command output.
        """
        # Build commands for Quick Tunnel mode
        # Note: SSM runs each command separately, so we need a single script
        github_token_str = github_token if github_token else ''

        script = f'''#!/bin/bash
set -e
START_TIME=$(date +%s)

log_timing() {{
    local STEP_NAME="$1"
    local STEP_END=$(date +%s)
    local ELAPSED=$((STEP_END - START_TIME))
    echo "[SSM_TIMING] $STEP_NAME completed at +${{ELAPSED}}s"
}}

export REPO_URL="{repo_url}"
export BRANCH="{branch}"
export GITHUB_TOKEN="{github_token_str}"

echo "Starting environment for $REPO_URL (branch: $BRANCH)"

# Start docker immediately (don't wait for systemctl)
sudo systemctl start docker &
DOCKER_PID=$!

cd /app
rm -rf repo

if [ -n "$GITHUB_TOKEN" ]; then
    AUTH_URL=$(echo "$REPO_URL" | sed "s|https://github.com|https://x-access-token:$GITHUB_TOKEN@github.com|")
    git clone --depth 1 --branch "$BRANCH" "$AUTH_URL" repo || exit 1
else
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" repo || exit 1
fi
log_timing "git_clone"
cd repo

# Wait for docker to be ready
wait $DOCKER_PID 2>/dev/null || true
while ! docker info >/dev/null 2>&1; do sleep 0.5; done
log_timing "docker_ready"

# Build and start containers
docker compose up -d --build || exit 1
log_timing "docker_compose_up"

# Start cloudflared tunnel
sudo /usr/local/bin/cloudflared tunnel --url http://localhost:80 > /tmp/cloudflared.log 2>&1 &
echo "Started cloudflared"

# Wait for tunnel URL (poll every 0.5s for faster response)
for i in $(seq 1 60); do
    TUNNEL_URL=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -1)
    if [ -n "$TUNNEL_URL" ]; then
        log_timing "tunnel_ready"
        echo "TUNNEL_URL=$TUNNEL_URL"
        echo "Environment started successfully"
        exit 0
    fi
    sleep 0.5
done

echo "ERROR: Tunnel URL not found"
cat /tmp/cloudflared.log
exit 1
'''

        return self.run_command(instance_id, [script], timeout=300)

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
