# Ephemeral Environments - AWS Outputs
# Values needed for Cloudflare Worker and other components

output "aws_region" {
  value       = local.region
  description = "AWS region where resources are deployed"
}

output "aws_account_id" {
  value       = local.account_id
  description = "AWS account ID"
}

output "sqs_queue_url" {
  value       = aws_sqs_queue.build_queue.url
  description = "SQS queue URL for Cloudflare Worker to send messages"
}

output "sqs_queue_arn" {
  value       = aws_sqs_queue.build_queue.arn
  description = "SQS queue ARN"
}

# Summary output for easy reference
output "summary" {
  value = <<-EOF

    === Ephemeral Environments AWS Infrastructure ===

    Region: ${local.region}
    Account: ${local.account_id}

    VPC: ${aws_vpc.main.id}
    Subnets: ${join(", ", aws_subnet.public[*].id)}

    SQS Queue URL: ${aws_sqs_queue.build_queue.url}

    Lambda Functions:
      - Deploy Worker: ${aws_lambda_function.deploy_worker.function_name}
      - Cleanup Worker: ${aws_lambda_function.cleanup_worker.function_name}

    DynamoDB Tables:
      - Environments: ${aws_dynamodb_table.environments.name}
      - Builds: ${aws_dynamodb_table.builds.name}

    Next Steps:
      1. Build AMI: make ami-build
      2. Deploy Cloudflare Worker: make worker-deploy
      3. Deploy Lambda code: make lambda-deploy

  EOF
  description = "Summary of deployed resources"
}
