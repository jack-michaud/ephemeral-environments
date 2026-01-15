# Ephemeral Environments - EC2 Configuration
# Launch template and IAM role for environment instances

# IAM role for environment instances
resource "aws_iam_role" "environment_instance" {
  name = "${local.name_prefix}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-instance-role"
  }
}

# Attach SSM managed policy for remote command execution
resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.environment_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Policy for ECR access (to pull private images if needed)
resource "aws_iam_role_policy" "ecr_access" {
  name = "ecr-access"
  role = aws_iam_role.environment_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      }
    ]
  })
}

# Policy for CloudWatch Logs
resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.environment_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/ephemeral-environments/*"
      }
    ]
  })
}

# Instance profile
resource "aws_iam_instance_profile" "environment" {
  name = "${local.name_prefix}-instance-profile"
  role = aws_iam_role.environment_instance.name
}

# Get latest Amazon Linux 2023 AMI (base for Packer)
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Launch template for environment instances
resource "aws_launch_template" "environment" {
  name_prefix   = "${local.name_prefix}-"
  image_id      = var.environment_ami_id != "" ? var.environment_ami_id : data.aws_ami.amazon_linux_2023.id
  instance_type = var.environment_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.environment.arn
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.environment.id]
  }

  # Enable detailed monitoring (optional, costs extra)
  monitoring {
    enabled = false
  }

  # User data script (will be overridden by SSM commands)
  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo "Environment instance starting..."
    # Cloudflared and docker-compose will be started via SSM
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.name_prefix}-environment"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${local.name_prefix}-environment-volume"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Outputs
output "launch_template_id" {
  value = aws_launch_template.environment.id
}

output "launch_template_latest_version" {
  value = aws_launch_template.environment.latest_version
}

output "instance_profile_arn" {
  value = aws_iam_instance_profile.environment.arn
}

output "base_ami_id" {
  value = data.aws_ami.amazon_linux_2023.id
}
