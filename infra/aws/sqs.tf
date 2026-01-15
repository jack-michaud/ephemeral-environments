# Ephemeral Environments - SQS Queues
# Free tier: 1M requests/month

# Main build queue
resource "aws_sqs_queue" "build_queue" {
  name                       = "ephemeral-build-queue"
  visibility_timeout_seconds = 900  # 15 minutes (Lambda timeout + buffer)
  message_retention_seconds  = 86400  # 1 day
  receive_wait_time_seconds  = 20  # Long polling

  # Dead letter queue for failed messages
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.build_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name = "ephemeral-build-queue"
  }
}

# Dead letter queue for failed builds
resource "aws_sqs_queue" "build_dlq" {
  name                      = "ephemeral-build-dlq"
  message_retention_seconds = 1209600  # 14 days

  tags = {
    Name = "ephemeral-build-dlq"
  }
}

# Queue policy to allow Cloudflare Worker to send messages
resource "aws_sqs_queue_policy" "build_queue_policy" {
  queue_url = aws_sqs_queue.build_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowSendMessage"
        Effect    = "Allow"
        Principal = "*"
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.build_queue.arn
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount" = local.account_id
          }
        }
      }
    ]
  })
}

# Outputs
output "build_queue_url" {
  value = aws_sqs_queue.build_queue.url
}

output "build_queue_arn" {
  value = aws_sqs_queue.build_queue.arn
}

output "build_dlq_url" {
  value = aws_sqs_queue.build_dlq.url
}
