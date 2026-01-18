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

  # IAM policy for accessing secrets (used by per-repo instance role)
  iam_policy_json = jsonencode({
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
  secret_id = aws_secretsmanager_secret.repo_secrets.id
  secret_string = jsonencode({
    instance_profile_arn = aws_iam_instance_profile.environment.arn
    secrets              = local.full_manifest
  })
}

# IAM role for EC2 instances running this repo's environments
resource "aws_iam_role" "environment_instance" {
  name = "${var.name_prefix}-instance-${local.repo_name_normalized}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name       = "${var.name_prefix}-instance-${local.repo_name_normalized}"
    Repository = var.repo_full_name
  })
}

# Attach SSM managed policy for remote command execution
resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.environment_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Base policies (ECR, CloudWatch, EC2 DescribeTags)
resource "aws_iam_role_policy" "base_policies" {
  name = "base-policies"
  role = aws_iam_role.environment_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ECR access
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      },
      # CloudWatch Logs
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:log-group:/ephemeral-environments/*"
      },
      # EC2 DescribeTags (to discover repo from instance metadata)
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeTags"]
        Resource = "*"
      }
    ]
  })
}

# Repo-specific secrets access policy
resource "aws_iam_role_policy" "secrets_access" {
  name   = "secrets-access"
  role   = aws_iam_role.environment_instance.id
  policy = local.iam_policy_json
}

# Instance profile for this repo
resource "aws_iam_instance_profile" "environment" {
  name = "${var.name_prefix}-instance-${local.repo_name_normalized}"
  role = aws_iam_role.environment_instance.name
}
