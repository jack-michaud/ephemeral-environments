# Ephemeral Environments - Packer AMI Definition
# Creates an AMI with Docker, docker-compose, and cloudflared pre-installed

packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

# Find the latest Amazon Linux 2023 AMI
data "amazon-ami" "amazon_linux_2023" {
  filters = {
    name                = "al2023-ami-*-x86_64"
    virtualization-type = "hvm"
    root-device-type    = "ebs"
  }
  most_recent = true
  owners      = ["amazon"]
  region      = var.aws_region
}

source "amazon-ebs" "environment" {
  ami_name        = "ephemeral-environment-{{timestamp}}"
  ami_description = "AMI for ephemeral environment instances with Docker, compose, and cloudflared"
  instance_type   = var.instance_type
  region          = var.aws_region
  source_ami      = data.amazon-ami.amazon_linux_2023.id

  ssh_username = "ec2-user"

  # Tag the AMI
  tags = {
    Name        = "ephemeral-environment"
    Project     = "ephemeral-environments"
    BuildTime   = "{{timestamp}}"
    BaseAMI     = data.amazon-ami.amazon_linux_2023.id
  }

  # Tag the snapshot
  snapshot_tags = {
    Name    = "ephemeral-environment"
    Project = "ephemeral-environments"
  }
}

build {
  name    = "ephemeral-environment"
  sources = ["source.amazon-ebs.environment"]

  # Update system
  provisioner "shell" {
    inline = [
      "sudo dnf update -y",
      "sudo dnf install -y git jq"
    ]
  }

  # Install Docker and pre-pull common base images
  provisioner "shell" {
    inline = [
      "sudo dnf install -y docker",
      "sudo systemctl enable docker",
      "sudo systemctl start docker",
      "sudo usermod -aG docker ec2-user",
      "# Pre-pull common base images to speed up first docker compose",
      "sudo docker pull python:3.11-slim",
      "sudo docker pull python:3.12-slim",
      "sudo docker pull node:20-slim",
      "sudo docker pull node:22-slim",
      "sudo docker pull nginx:alpine",
      "sudo docker pull alpine:latest"
    ]
  }

  # Install Docker Buildx (required for docker compose build)
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /usr/local/lib/docker/cli-plugins",
      "sudo curl -SL https://github.com/docker/buildx/releases/download/v0.19.3/buildx-v0.19.3.linux-amd64 -o /usr/local/lib/docker/cli-plugins/docker-buildx",
      "sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx"
    ]
  }

  # Install Docker Compose v2 (as Docker plugin)
  provisioner "shell" {
    inline = [
      "sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose",
      "sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose",
      "# Also install standalone for compatibility",
      "sudo ln -s /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose"
    ]
  }

  # Install cloudflared (direct binary download for Amazon Linux)
  provisioner "shell" {
    inline = [
      "sudo curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared",
      "sudo chmod +x /usr/local/bin/cloudflared",
      "cloudflared --version"
    ]
  }

  # Create working directory
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /app",
      "sudo chown ec2-user:ec2-user /app"
    ]
  }

  # Create systemd service for cloudflared (will be configured at runtime)
  provisioner "shell" {
    inline = [
      "sudo tee /etc/systemd/system/cloudflared.service > /dev/null <<'EOF'",
      "[Unit]",
      "Description=Cloudflare Tunnel",
      "After=network.target docker.service",
      "Wants=docker.service",
      "",
      "[Service]",
      "Type=simple",
      "User=root",
      "EnvironmentFile=/etc/cloudflared/tunnel.env",
      "ExecStart=/usr/local/bin/cloudflared tunnel run --token $${TUNNEL_TOKEN}",
      "Restart=on-failure",
      "RestartSec=5",
      "",
      "[Install]",
      "WantedBy=multi-user.target",
      "EOF",
      "",
      "sudo mkdir -p /etc/cloudflared",
      "sudo systemctl daemon-reload"
    ]
  }

  # Create startup script (called by SSM)
  provisioner "shell" {
    inline = [
      "sudo tee /usr/local/bin/start-environment.sh > /dev/null <<'SCRIPT'",
      "#!/bin/bash",
      "set -e",
      "",
      "# Arguments: REPO_URL BRANCH TUNNEL_TOKEN [GITHUB_TOKEN]",
      "REPO_URL=$1",
      "BRANCH=$2",
      "TUNNEL_TOKEN=$3",
      "GITHUB_TOKEN=$4",
      "",
      "echo \"Starting environment for $REPO_URL (branch: $BRANCH)\"",
      "",
      "# Clone repository (use token for private repos if provided)",
      "cd /app",
      "rm -rf repo",
      "",
      "if [ -n \"$GITHUB_TOKEN\" ]; then",
      "  # Convert https://github.com/owner/repo.git to authenticated URL",
      "  AUTH_URL=$(echo \"$REPO_URL\" | sed \"s|https://github.com|https://x-access-token:$${GITHUB_TOKEN}@github.com|\")",
      "  git clone --depth 1 --branch \"$BRANCH\" \"$AUTH_URL\" repo",
      "else",
      "  git clone --depth 1 --branch \"$BRANCH\" \"$REPO_URL\" repo",
      "fi",
      "cd repo",
      "",
      "# Start Docker",
      "sudo systemctl start docker",
      "",
      "# Run docker-compose",
      "docker compose up -d --build",
      "",
      "# Configure and start cloudflared with tunnel token",
      "echo \"TUNNEL_TOKEN=$TUNNEL_TOKEN\" | sudo tee /etc/cloudflared/tunnel.env > /dev/null",
      "sudo chmod 600 /etc/cloudflared/tunnel.env",
      "sudo systemctl start cloudflared",
      "",
      "echo \"Environment started successfully\"",
      "SCRIPT",
      "",
      "sudo chmod +x /usr/local/bin/start-environment.sh"
    ]
  }

  # Install fetch-secrets script for IAM-based secret retrieval
  provisioner "shell" {
    inline = [
      "sudo tee /usr/local/bin/fetch-secrets.sh > /dev/null <<'SCRIPT'",
      "#!/bin/bash",
      "set -e",
      "",
      "# Get instance metadata via IMDSv2",
      "TOKEN=$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')",
      "INSTANCE_ID=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/instance-id)",
      "REGION=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/placement/region)",
      "",
      "echo \"[fetch-secrets] Instance: $INSTANCE_ID, Region: $REGION\" >&2",
      "",
      "# Get Repository tag from instance",
      "REPO=$(aws ec2 describe-tags --region \"$REGION\" \\",
      "  --filters \"Name=resource-id,Values=$INSTANCE_ID\" \"Name=key,Values=Repository\" \\",
      "  --query 'Tags[0].Value' --output text)",
      "",
      "if [ \"$REPO\" == \"None\" ] || [ -z \"$REPO\" ]; then",
      "  echo \"[fetch-secrets] No Repository tag found\" >&2",
      "  exit 0",
      "fi",
      "",
      "echo \"[fetch-secrets] Repository: $REPO\" >&2",
      "",
      "# Fetch secrets manifest from Secrets Manager",
      "SECRET_NAME=\"ephemeral-env/repos/$REPO\"",
      "CONFIG=$(aws secretsmanager get-secret-value --region \"$REGION\" \\",
      "  --secret-id \"$SECRET_NAME\" --query 'SecretString' --output text 2>/dev/null || echo '{}')",
      "",
      "# Extract secrets from manifest (new format has 'secrets' key)",
      "MANIFEST=$(echo \"$CONFIG\" | jq -r '.secrets // .')",
      "",
      "if [ \"$MANIFEST\" == \"{}\" ] || [ \"$MANIFEST\" == \"null\" ]; then",
      "  echo \"[fetch-secrets] No secrets configured for $REPO\" >&2",
      "  exit 0",
      "fi",
      "",
      "# Process each secret in the manifest",
      "echo \"$MANIFEST\" | jq -r 'to_entries[] | \"\\(.key)|\\(.value.type)|\\(.value.value // .value.arn // .value.path)\"' | \\",
      "while IFS='|' read -r ENV_NAME SECRET_TYPE SECRET_REF; do",
      "  case \"$SECRET_TYPE\" in",
      "    direct)",
      "      VALUE=\"$SECRET_REF\"",
      "      ;;",
      "    secretsmanager)",
      "      VALUE=$(aws secretsmanager get-secret-value --region \"$REGION\" \\",
      "        --secret-id \"$SECRET_REF\" --query 'SecretString' --output text 2>/dev/null || echo '')",
      "      ;;",
      "    ssm)",
      "      VALUE=$(aws ssm get-parameter --region \"$REGION\" \\",
      "        --name \"$SECRET_REF\" --with-decryption \\",
      "        --query 'Parameter.Value' --output text 2>/dev/null || echo '')",
      "      ;;",
      "    *)",
      "      echo \"[fetch-secrets] Unknown type: $SECRET_TYPE for $ENV_NAME\" >&2",
      "      continue",
      "      ;;",
      "  esac",
      "",
      "  if [ -n \"$VALUE\" ]; then",
      "    ESCAPED=$(echo \"$VALUE\" | sed \"s/'/'\\\\\\\\''/g\")",
      "    echo \"export $ENV_NAME='$ESCAPED'\"",
      "  fi",
      "done",
      "",
      "echo \"[fetch-secrets] Done\" >&2",
      "SCRIPT",
      "",
      "sudo chmod +x /usr/local/bin/fetch-secrets.sh"
    ]
  }

  # Clean up
  provisioner "shell" {
    inline = [
      "sudo dnf clean all",
      "sudo rm -rf /var/cache/dnf/*",
      "sudo rm -rf /tmp/*"
    ]
  }
}
