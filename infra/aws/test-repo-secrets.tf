# Test Repository Secrets Configuration
# Used for E2E testing of the secrets injection feature

module "test_repo_secrets" {
  source = "../modules/ephemeral-repo-secrets"

  repo_full_name = "jack-michaud/ephemeral-envs-test"
  name_prefix    = local.name_prefix

  # Direct test secret for E2E verification
  secrets = {
    TEST_SECRET = var.test_repo_secret
  }

  tags = {
    Purpose = "e2e-testing"
  }
}

variable "test_repo_secret" {
  description = "Test secret value for E2E testing of secrets injection"
  type        = string
  default     = "e2e-test-secret-value-12345"
  sensitive   = true
}

output "test_repo_secret_arn" {
  description = "ARN of the test repo secrets manifest"
  value       = module.test_repo_secrets.secret_arn
}
