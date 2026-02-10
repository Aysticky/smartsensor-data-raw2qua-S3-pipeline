output "glue_execution_role_arn" {
  description = "ARN of the Glue execution role"
  value       = aws_iam_role.glue_execution.arn
}

output "glue_execution_role_name" {
  description = "Name of the Glue execution role"
  value       = aws_iam_role.glue_execution.name
}
