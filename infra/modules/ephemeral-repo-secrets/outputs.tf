# Ephemeral Repo Secrets Module - Outputs

output "secret_arn" {
  description = "ARN of the secrets manifest in Secrets Manager"
  value       = aws_secretsmanager_secret.repo_secrets.arn
}

output "secret_name" {
  description = "Name of the secrets manifest in Secrets Manager"
  value       = aws_secretsmanager_secret.repo_secrets.name
}

output "repo_full_name" {
  description = "Repository this secret configuration is for"
  value       = var.repo_full_name
}

output "secret_names" {
  description = "List of environment variable names that will be injected"
  value       = keys(local.full_manifest)
}

output "referenced_secret_arns" {
  description = "List of Secrets Manager ARNs that need to be accessible by the deployer"
  value       = values(var.secrets_manager_refs)
}

output "referenced_ssm_paths" {
  description = "List of SSM parameter paths that need to be accessible by the deployer"
  value       = values(var.ssm_refs)
}

output "iam_policy_json" {
  description = "IAM policy document granting access to all referenced secrets (attach to deployer role)"
  value = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      # Access to the manifest itself
      [{
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.repo_secrets.arn]
      }],
      # Access to referenced Secrets Manager secrets
      length(var.secrets_manager_refs) > 0 ? [{
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = values(var.secrets_manager_refs)
      }] : [],
      # Access to referenced SSM parameters
      length(var.ssm_refs) > 0 ? [{
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = [for path in values(var.ssm_refs) : "arn:aws:ssm:*:*:parameter${path}"]
      }] : []
    )
  })
}
