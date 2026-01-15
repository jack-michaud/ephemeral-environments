# Ephemeral Environments - Lambda Functions
# Deploy worker (triggered by SQS) and Cleanup worker (triggered by EventBridge)

# IAM role for Lambda functions
resource "aws_iam_role" "lambda" {
  name = "${local.name_prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-lambda-role"
  }
}

# Lambda basic execution (CloudWatch Logs)
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda VPC access (if needed)
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Custom policy for Lambda
resource "aws_iam_role_policy" "lambda_custom" {
  name = "lambda-custom-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # EC2 management
      {
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:StopInstances",
          "ec2:StartInstances",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:CreateTags",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      },
      # SSM for remote commands
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:ListCommands",
          "ssm:ListCommandInvocations"
        ]
        Resource = "*"
      },
      # DynamoDB access
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.environments.arn,
          "${aws_dynamodb_table.environments.arn}/index/*",
          aws_dynamodb_table.builds.arn
        ]
      },
      # SQS access
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.build_queue.arn
      },
      # IAM PassRole for EC2
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.environment_instance.arn
      },
      # Secrets Manager (for GitHub App private key)
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.github_app.arn
      }
    ]
  })
}

# Secrets Manager for GitHub App credentials
resource "aws_secretsmanager_secret" "github_app" {
  name        = "${local.name_prefix}/github-app"
  description = "GitHub App credentials for ephemeral environments"

  tags = {
    Name = "${local.name_prefix}-github-app-secret"
  }
}

resource "aws_secretsmanager_secret_version" "github_app" {
  secret_id = aws_secretsmanager_secret.github_app.id
  secret_string = jsonencode({
    app_id         = var.github_app_id
    private_key    = var.github_app_private_key
    webhook_secret = var.github_webhook_secret
  })
}

# Secrets Manager for Cloudflare credentials
resource "aws_secretsmanager_secret" "cloudflare" {
  name        = "${local.name_prefix}/cloudflare"
  description = "Cloudflare credentials for ephemeral environments"

  tags = {
    Name = "${local.name_prefix}-cloudflare-secret"
  }
}

resource "aws_secretsmanager_secret_version" "cloudflare" {
  secret_id = aws_secretsmanager_secret.cloudflare.id
  secret_string = jsonencode({
    api_token  = var.cloudflare_api_token
    account_id = var.cloudflare_account_id
  })
}

# Update Lambda policy to access Cloudflare secret
resource "aws_iam_role_policy" "lambda_secrets" {
  name = "lambda-secrets-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.github_app.arn,
          aws_secretsmanager_secret.cloudflare.arn
        ]
      }
    ]
  })
}

# Deploy Worker Lambda
resource "aws_lambda_function" "deploy_worker" {
  function_name = "${local.name_prefix}-deploy-worker"
  role          = aws_iam_role.lambda.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.11"
  timeout       = 900  # 15 minutes (EC2 launch + docker-compose can take a while)
  memory_size   = 256

  # Placeholder - will be updated by make lambda-deploy
  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  environment {
    variables = {
      ENVIRONMENTS_TABLE    = aws_dynamodb_table.environments.name
      BUILDS_TABLE          = aws_dynamodb_table.builds.name
      LAUNCH_TEMPLATE_ID    = aws_launch_template.environment.id
      SUBNET_IDS            = join(",", aws_subnet.public[*].id)
      SECURITY_GROUP_ID     = aws_security_group.environment.id
      GITHUB_SECRET_ARN     = aws_secretsmanager_secret.github_app.arn
      CLOUDFLARE_SECRET_ARN = aws_secretsmanager_secret.cloudflare.arn
    }
  }

  tags = {
    Name = "${local.name_prefix}-deploy-worker"
  }
}

# SQS trigger for Deploy Worker
resource "aws_lambda_event_source_mapping" "deploy_worker_sqs" {
  event_source_arn = aws_sqs_queue.build_queue.arn
  function_name    = aws_lambda_function.deploy_worker.arn
  batch_size       = 1  # Process one at a time for now
}

# Cleanup Worker Lambda
resource "aws_lambda_function" "cleanup_worker" {
  function_name = "${local.name_prefix}-cleanup-worker"
  role          = aws_iam_role.lambda.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.11"
  timeout       = 300  # 5 minutes
  memory_size   = 128

  # Placeholder - will be updated by make lambda-deploy
  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  environment {
    variables = {
      ENVIRONMENTS_TABLE    = aws_dynamodb_table.environments.name
      AUTO_STOP_HOURS       = tostring(var.auto_stop_hours)
      CLOUDFLARE_SECRET_ARN = aws_secretsmanager_secret.cloudflare.arn
    }
  }

  tags = {
    Name = "${local.name_prefix}-cleanup-worker"
  }
}

# EventBridge rule for Cleanup Worker (every 15 minutes)
resource "aws_cloudwatch_event_rule" "cleanup_schedule" {
  name                = "${local.name_prefix}-cleanup-schedule"
  description         = "Trigger cleanup worker every 15 minutes"
  schedule_expression = "rate(15 minutes)"

  tags = {
    Name = "${local.name_prefix}-cleanup-schedule"
  }
}

resource "aws_cloudwatch_event_target" "cleanup_lambda" {
  rule      = aws_cloudwatch_event_rule.cleanup_schedule.name
  target_id = "cleanup-worker"
  arn       = aws_lambda_function.cleanup_worker.arn
}

resource "aws_lambda_permission" "cleanup_eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cleanup_worker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cleanup_schedule.arn
}

# Placeholder Lambda package (will be replaced by actual code)
data "archive_file" "lambda_placeholder" {
  type        = "zip"
  output_path = "${path.module}/placeholder.zip"

  source {
    content  = <<-EOF
      def lambda_handler(event, context):
          return {"statusCode": 200, "body": "Placeholder - deploy actual code with make lambda-deploy"}
    EOF
    filename = "handler.py"
  }
}

# Outputs
output "deploy_worker_arn" {
  value = aws_lambda_function.deploy_worker.arn
}

output "deploy_worker_name" {
  value = aws_lambda_function.deploy_worker.function_name
}

output "cleanup_worker_arn" {
  value = aws_lambda_function.cleanup_worker.arn
}

output "cleanup_worker_name" {
  value = aws_lambda_function.cleanup_worker.function_name
}

output "github_secret_arn" {
  value = aws_secretsmanager_secret.github_app.arn
}

output "cloudflare_secret_arn" {
  value = aws_secretsmanager_secret.cloudflare.arn
}
