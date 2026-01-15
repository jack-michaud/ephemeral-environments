# Ephemeral Environments - AWS Variables

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "environment_instance_type" {
  description = "EC2 instance type for environments"
  type        = string
  default     = "t3.small"
}

variable "environment_ami_id" {
  description = "AMI ID for environment instances (built by Packer)"
  type        = string
  default     = ""  # If empty, uses latest Amazon Linux 2023
}

variable "max_environments" {
  description = "Maximum number of concurrent environments"
  type        = number
  default     = 20
}

variable "auto_stop_hours" {
  description = "Hours of inactivity before auto-stopping environment"
  type        = number
  default     = 4
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID for tunnel configuration"
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API Token"
  type        = string
  sensitive   = true
}

variable "github_app_id" {
  description = "GitHub App ID"
  type        = string
}

variable "github_app_private_key" {
  description = "GitHub App private key (PEM format)"
  type        = string
  sensitive   = true
}

variable "github_webhook_secret" {
  description = "GitHub webhook secret"
  type        = string
  sensitive   = true
}
