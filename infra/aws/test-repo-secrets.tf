# Test Repository Secrets Configuration
# Used for E2E testing of the secrets injection feature

# Secrets Manager secret for testing secretsmanager reference resolution
resource "aws_secretsmanager_secret" "test_sm_secret" {
  name        = "${local.name_prefix}/test/secretsmanager-secret"
  description = "Test secret for E2E testing of Secrets Manager reference resolution"

  tags = {
    Purpose = "e2e-testing"
  }
}

resource "aws_secretsmanager_secret_version" "test_sm_secret" {
  secret_id     = aws_secretsmanager_secret.test_sm_secret.id
  secret_string = var.test_secretsmanager_value
}

# SSM Parameter Store secret for testing ssm reference resolution
resource "aws_ssm_parameter" "test_ssm_secret" {
  name        = "/${local.name_prefix}/test/ssm-parameter"
  description = "Test parameter for E2E testing of SSM Parameter Store reference resolution"
  type        = "SecureString"
  value       = var.test_ssm_value

  tags = {
    Purpose = "e2e-testing"
  }
}

module "test_repo_secrets" {
  source = "../modules/ephemeral-repo-secrets"

  repo_full_name = "jack-michaud/ephemeral-envs-test"
  name_prefix    = local.name_prefix

  # Direct test secret for E2E verification
  secrets = {
    TEST_SECRET = var.test_repo_secret
  }

  # Secrets Manager reference test
  secrets_manager_refs = {
    TEST_SM_SECRET = aws_secretsmanager_secret.test_sm_secret.arn
  }

  # SSM Parameter Store reference test
  ssm_refs = {
    TEST_SSM_SECRET = aws_ssm_parameter.test_ssm_secret.name
  }

  tags = {
    Purpose = "e2e-testing"
  }
}

variable "test_repo_secret" {
  description = "Test secret value for E2E testing of direct secrets injection"
  type        = string
  default     = "e2e-test-secret-value-12345"
  sensitive   = true
}

variable "test_secretsmanager_value" {
  description = "Test value for Secrets Manager reference E2E testing"
  type        = string
  default     = "e2e-secretsmanager-resolved-value"
  sensitive   = true
}

variable "test_ssm_value" {
  description = "Test value for SSM Parameter Store reference E2E testing"
  type        = string
  default     = "e2e-ssm-parameter-resolved-value"
  sensitive   = true
}

output "test_repo_secret_arn" {
  description = "ARN of the test repo secrets manifest"
  value       = module.test_repo_secrets.secret_arn
}

output "test_secretsmanager_secret_arn" {
  description = "ARN of the test Secrets Manager secret"
  value       = aws_secretsmanager_secret.test_sm_secret.arn
}

output "test_ssm_parameter_name" {
  description = "Name of the test SSM parameter"
  value       = aws_ssm_parameter.test_ssm_secret.name
}
