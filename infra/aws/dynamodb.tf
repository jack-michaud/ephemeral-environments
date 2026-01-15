# Ephemeral Environments - DynamoDB Tables
# Pay-per-request billing = $0 when idle

# Environments table
# PK: repo#pr_number (e.g., "owner/repo#42")
resource "aws_dynamodb_table" "environments" {
  name         = "ephemeral-environments"
  billing_mode = "PAY_PER_REQUEST"  # Scale to zero!
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  # GSI for querying by status
  attribute {
    name = "status"
    type = "S"
  }

  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    projection_type = "ALL"
  }

  # TTL for auto-cleanup of old records
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Name = "ephemeral-environments"
  }
}

# Builds table
# PK: environment_id, SK: build_id
resource "aws_dynamodb_table" "builds" {
  name         = "ephemeral-builds"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "environment_id"
  range_key    = "build_id"

  attribute {
    name = "environment_id"
    type = "S"
  }

  attribute {
    name = "build_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Name = "ephemeral-builds"
  }
}

# Outputs
output "environments_table_name" {
  value = aws_dynamodb_table.environments.name
}

output "environments_table_arn" {
  value = aws_dynamodb_table.environments.arn
}

output "builds_table_name" {
  value = aws_dynamodb_table.builds.name
}

output "builds_table_arn" {
  value = aws_dynamodb_table.builds.arn
}
