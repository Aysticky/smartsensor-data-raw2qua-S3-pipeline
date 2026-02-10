output "schedule_rule_name" {
  description = "Name of the EventBridge rule"
  value       = aws_cloudwatch_event_rule.daily_pipeline.name
}

output "schedule_rule_arn" {
  description = "ARN of the EventBridge rule"
  value       = aws_cloudwatch_event_rule.daily_pipeline.arn
}

output "eventbridge_role_arn" {
  description = "ARN of the EventBridge execution role"
  value       = aws_iam_role.eventbridge_sfn.arn
}
