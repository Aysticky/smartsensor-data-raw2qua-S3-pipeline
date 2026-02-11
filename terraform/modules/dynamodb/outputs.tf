output "table_name" {
  description = "Name of the DynamoDB checkpoints table"
  value       = aws_dynamodb_table.pipeline_checkpoints.name
}

output "table_arn" {
  description = "ARN of the DynamoDB checkpoints table"
  value       = aws_dynamodb_table.pipeline_checkpoints.arn
}
