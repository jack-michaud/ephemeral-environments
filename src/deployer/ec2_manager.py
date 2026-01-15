"""
EC2 Manager - Handles EC2 instance lifecycle.
"""

import time
import logging
import boto3

logger = logging.getLogger(__name__)


class EC2Manager:
    def __init__(self, launch_template_id: str, subnet_ids: list, security_group_id: str):
        self.ec2 = boto3.client('ec2')
        self.launch_template_id = launch_template_id
        self.subnet_ids = subnet_ids
        self.security_group_id = security_group_id

    def launch_instance(self, name: str, tags: dict = None) -> str:
        """Launch a new EC2 instance from the launch template."""
        all_tags = [{'Key': 'Name', 'Value': name}]
        if tags:
            all_tags.extend([{'Key': k, 'Value': v} for k, v in tags.items()])

        response = self.ec2.run_instances(
            LaunchTemplate={'LaunchTemplateId': self.launch_template_id, 'Version': '$Latest'},
            MinCount=1,
            MaxCount=1,
            NetworkInterfaces=[{
                'DeviceIndex': 0,
                'SubnetId': self.subnet_ids[0],
                'AssociatePublicIpAddress': True,
                'Groups': [self.security_group_id]
            }],
            TagSpecifications=[
                {
                    'ResourceType': 'instance',
                    'Tags': all_tags
                }
            ]
        )

        instance_id = response['Instances'][0]['InstanceId']
        logger.info(f"Launched instance: {instance_id}")
        return instance_id

    def wait_for_instance(self, instance_id: str, timeout: int = 300):
        """Wait for instance to be running and SSM ready."""
        logger.info(f"Waiting for instance {instance_id} to be ready...")

        # Wait for instance to be running
        waiter = self.ec2.get_waiter('instance_running')
        waiter.wait(
            InstanceIds=[instance_id],
            WaiterConfig={'Delay': 5, 'MaxAttempts': timeout // 5}
        )

        # Wait for status checks
        waiter = self.ec2.get_waiter('instance_status_ok')
        waiter.wait(
            InstanceIds=[instance_id],
            WaiterConfig={'Delay': 10, 'MaxAttempts': timeout // 10}
        )

        # Additional wait for SSM agent
        ssm = boto3.client('ssm')
        start_time = time.time()
        while time.time() - start_time < 120:  # 2 minute timeout
            try:
                response = ssm.describe_instance_information(
                    Filters=[{'Key': 'InstanceIds', 'Values': [instance_id]}]
                )
                if response.get('InstanceInformationList'):
                    logger.info(f"Instance {instance_id} is SSM ready")
                    return
            except Exception:
                pass
            time.sleep(10)

        logger.warning(f"Instance {instance_id} may not be fully SSM ready")

    def stop_instance(self, instance_id: str):
        """Stop an EC2 instance."""
        try:
            self.ec2.stop_instances(InstanceIds=[instance_id])
            logger.info(f"Stopped instance: {instance_id}")
        except Exception as e:
            logger.error(f"Failed to stop instance {instance_id}: {e}")

    def start_instance(self, instance_id: str):
        """Start a stopped EC2 instance."""
        try:
            self.ec2.start_instances(InstanceIds=[instance_id])
            logger.info(f"Started instance: {instance_id}")
        except Exception as e:
            logger.error(f"Failed to start instance {instance_id}: {e}")

    def terminate_instance(self, instance_id: str):
        """Terminate an EC2 instance."""
        try:
            self.ec2.terminate_instances(InstanceIds=[instance_id])
            logger.info(f"Terminated instance: {instance_id}")
        except Exception as e:
            logger.error(f"Failed to terminate instance {instance_id}: {e}")

    def get_instance_state(self, instance_id: str) -> str:
        """Get the current state of an instance."""
        try:
            response = self.ec2.describe_instances(InstanceIds=[instance_id])
            if response['Reservations']:
                return response['Reservations'][0]['Instances'][0]['State']['Name']
        except Exception as e:
            logger.error(f"Failed to get instance state: {e}")
        return 'unknown'
