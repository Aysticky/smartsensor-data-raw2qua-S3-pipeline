output "data_bucket_name" {
  description = "Name of the data lake S3 bucket"
  value       = module.s3.bucket_name
}

output "glue_check_job_name" {
  description = "Name of the check Glue job"
  value       = module.glue.check_job_name
}

output "glue_extract_job_name" {
  description = "Name of the extract Glue job"
  value       = module.glue.extract_job_name
}

output "state_machine_arn" {
  description = "ARN of the Step Functions state machine"
  value       = module.stepfunctions.state_machine_arn
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge schedule rule"
  value       = module.eventbridge.schedule_rule_name
}

output "deployment_summary" {
  description = "Summary of deployed resources"
  value = {
    environment        = "dev"
    region             = var.aws_region
    account_id         = data.aws_caller_identity.current.account_id
    data_bucket        = module.s3.bucket_name
    check_job          = module.glue.check_job_name
    extract_job        = module.glue.extract_job_name
    state_machine      = module.stepfunctions.state_machine_name
    schedule_enabled   = false
    glue_version       = "4.0"
    worker_type        = "G.1X"
    num_workers        = 2
  }
}
