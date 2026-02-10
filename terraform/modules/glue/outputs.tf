output "check_job_name" {
  description = "Name of the check Glue job"
  value       = aws_glue_job.check_api.name
}

output "check_job_arn" {
  description = "ARN of the check Glue job"
  value       = aws_glue_job.check_api.arn
}

output "extract_job_name" {
  description = "Name of the extract Glue job"
  value       = aws_glue_job.extract_data.name
}

output "extract_job_arn" {
  description = "ARN of the extract Glue job"
  value       = aws_glue_job.extract_data.arn
}

output "scripts_bucket_name" {
  description = "Name of the Glue scripts bucket"
  value       = aws_s3_bucket.glue_scripts.id
}

output "scripts_bucket_arn" {
  description = "ARN of the Glue scripts bucket"
  value       = aws_s3_bucket.glue_scripts.arn
}
