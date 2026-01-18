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
  value       = local.iam_policy_json
}

output "instance_profile_arn" {
  description = "ARN of the IAM instance profile for EC2 instances running this repo"
  value       = aws_iam_instance_profile.environment.arn
}

output "instance_profile_name" {
  description = "Name of the IAM instance profile"
  value       = aws_iam_instance_profile.environment.name
}

output "iam_role_arn" {
  description = "ARN of the IAM role for EC2 instances"
  value       = aws_iam_role.environment_instance.arn
}
