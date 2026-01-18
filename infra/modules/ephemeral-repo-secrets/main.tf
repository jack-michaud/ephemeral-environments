# Ephemeral Repo Secrets Module
# Registers secrets for a repository to be injected into ephemeral environments

locals {
  # Normalize repo name for use in resource names (replace / with -)
  repo_name_normalized = replace(var.repo_full_name, "/", "-")

  # Build the manifest that describes all secret sources
  # The deployer will read this manifest and fetch secrets accordingly
  manifest = {
    for name, value in var.secrets : name => {
      type  = "direct"
      value = value
    }
  }

  manifest_refs = {
    for name, arn in var.secrets_manager_refs : name => {
      type = "secretsmanager"
      arn  = arn
    }
  }

  manifest_ssm = {
    for name, path in var.ssm_refs : name => {
      type = "ssm"
      path = path
    }
  }

  # Merge all sources into a single manifest
  full_manifest = merge(local.manifest, local.manifest_refs, local.manifest_ssm)
}

# Store the secrets manifest in Secrets Manager
# Path: {prefix}/repos/{owner}/{repo}
resource "aws_secretsmanager_secret" "repo_secrets" {
  name        = "${var.name_prefix}/repos/${var.repo_full_name}"
  description = "Secrets manifest for ephemeral environments: ${var.repo_full_name}"

  tags = merge(var.tags, {
    Name       = "${var.name_prefix}-repo-secrets-${local.repo_name_normalized}"
    Repository = var.repo_full_name
    ManagedBy  = "terraform"
  })
}

resource "aws_secretsmanager_secret_version" "repo_secrets" {
  secret_id     = aws_secretsmanager_secret.repo_secrets.id
  secret_string = jsonencode(local.full_manifest)
}
