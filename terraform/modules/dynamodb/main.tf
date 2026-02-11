# DynamoDB Table for Pipeline Checkpoints
#
# PURPOSE:
# - Track last processed date for incremental data loading
# - Store job execution metadata
# - Enable idempotent pipeline runs
#
# CHECKPOINT PATTERN:
# - Primary Key: job_name (e.g., "extract_weather_data")
# - Attributes: last_processed_date, last_execution_id, status, updated_at
# - Before job runs: Read last_processed_date
# - After job succeeds: Update last_processed_date to latest date
# - On failure: Keep old checkpoint, retry from same point
#
# COST:
# - On-demand pricing: $1.25 per million writes, $0.25 per million reads
# - For daily pipeline: ~2 operations/day = $0.00 per month
# - Point-in-time recovery adds ~$0.20/month

resource "aws_dynamodb_table" "pipeline_checkpoints" {
  name         = "${var.project_name}-${var.environment}-checkpoints"
  billing_mode = "PAY_PER_REQUEST" # On-demand pricing for low-volume workloads
  hash_key     = "job_name"

  attribute {
    name = "job_name"
    type = "S"
  }

  # Enable point-in-time recovery for production
  point_in_time_recovery {
    enabled = var.enable_pitr
  }

  # Server-side encryption
  server_side_encryption {
    enabled = true
  }

  # TTL for automatic cleanup of old metadata (optional)
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(
    var.common_tags,
    {
      Name    = "${var.project_name}-${var.environment}-checkpoints"
      Purpose = "Pipeline checkpoint tracking"
    }
  )
}

# Initial checkpoint item for extract job
resource "aws_dynamodb_table_item" "extract_job_checkpoint" {
  table_name = aws_dynamodb_table.pipeline_checkpoints.name
  hash_key   = aws_dynamodb_table.pipeline_checkpoints.hash_key

  # Initialize with a date far in the past to fetch all data on first run
  item = jsonencode({
    job_name = {
      S = "extract_weather_data"
    }
    last_processed_date = {
      S = var.initial_start_date
    }
    status = {
      S = "initialized"
    }
    updated_at = {
      S = timestamp()
    }
    description = {
      S = "Checkpoint for weather data extraction job"
    }
  })

  lifecycle {
    ignore_changes = [
      item # Don't overwrite after initial creation
    ]
  }
}
