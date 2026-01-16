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

  # Clean up
  provisioner "shell" {
    inline = [
      "sudo dnf clean all",
      "sudo rm -rf /var/cache/dnf/*",
      "sudo rm -rf /tmp/*"
    ]
  }
}
