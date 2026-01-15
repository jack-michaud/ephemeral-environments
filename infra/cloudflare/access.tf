# Ephemeral Environments - Cloudflare Access Configuration
# Note: Individual Access applications for each environment are created dynamically
# by the deploy Lambda. This Terraform sets up the base configuration.

# GitHub Identity Provider (optional - provides seamless SSO)
# If not configured, users will use email-based one-time PIN
resource "cloudflare_access_identity_provider" "github" {
  count      = var.github_client_id != "" ? 1 : 0
  account_id = var.cloudflare_account_id
  name       = "GitHub"
  type       = "github"

  config {
    client_id     = var.github_client_id
    client_secret = var.github_client_secret
  }
}

# Access group for GitHub users (used by dynamic policies)
# The deploy Lambda will reference this group when creating per-environment policies
resource "cloudflare_access_group" "github_users" {
  account_id = var.cloudflare_account_id
  name       = "ephemeral-environments-github-users"

  include {
    # Allow anyone who authenticates via GitHub
    # Per-environment policies will further restrict to PR participants
    login_method = var.github_client_id != "" ? ["github"] : []
  }

  # If no GitHub IdP, allow email-based auth
  dynamic "include" {
    for_each = var.github_client_id == "" ? [1] : []
    content {
      email_domain = ["gmail.com", "github.com"]  # Adjust as needed
    }
  }
}

# Service Token for E2E testing (bypasses OAuth)
resource "cloudflare_access_service_token" "test" {
  account_id = var.cloudflare_account_id
  name       = "ephemeral-environments-test"

  # Note: duration cannot be set via Terraform, defaults to 1 year
}

# Outputs
output "github_idp_id" {
  value       = length(cloudflare_access_identity_provider.github) > 0 ? cloudflare_access_identity_provider.github[0].id : null
  description = "GitHub Identity Provider ID (if configured)"
}

output "github_users_group_id" {
  value       = cloudflare_access_group.github_users.id
  description = "Access Group ID for GitHub users"
}

output "test_service_token_id" {
  value       = cloudflare_access_service_token.test.client_id
  description = "Service Token Client ID for E2E tests"
  sensitive   = true
}

output "test_service_token_secret" {
  value       = cloudflare_access_service_token.test.client_secret
  description = "Service Token Client Secret for E2E tests"
  sensitive   = true
}

output "summary" {
  value = <<-EOF

    === Ephemeral Environments Cloudflare Infrastructure ===

    Account ID: ${var.cloudflare_account_id}

    GitHub Identity Provider: ${length(cloudflare_access_identity_provider.github) > 0 ? "Configured" : "Not configured (using email auth)"}

    Access Group: ${cloudflare_access_group.github_users.name}

    Service Token for Testing:
      Client ID: ${cloudflare_access_service_token.test.client_id}
      (Run: terraform output -raw test_service_token_secret)

    Note: Per-environment Access applications are created dynamically
    by the deploy Lambda when environments are spun up.

  EOF
  description = "Summary of deployed resources"
}
