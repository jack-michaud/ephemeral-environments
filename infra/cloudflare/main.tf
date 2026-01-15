# Ephemeral Environments - Cloudflare Infrastructure
# Access application and GitHub identity provider

terraform {
  required_version = ">= 1.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Variables
variable "cloudflare_api_token" {
  description = "Cloudflare API Token"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
}

variable "github_client_id" {
  description = "GitHub OAuth App Client ID (for Access)"
  type        = string
  default     = ""  # Optional - can use one-time PIN if not set
}

variable "github_client_secret" {
  description = "GitHub OAuth App Client Secret (for Access)"
  type        = string
  sensitive   = true
  default     = ""  # Optional - can use one-time PIN if not set
}
