output "bucket_name" {
  description = "Name of the data lake bucket"
  value       = aws_s3_bucket.data_lake.id
}

output "bucket_arn" {
  description = "ARN of the data lake bucket"
  value       = aws_s3_bucket.data_lake.arn
}

output "bucket_domain_name" {
  description = "Domain name of the bucket"
  value       = aws_s3_bucket.data_lake.bucket_domain_name
}

output "access_logs_bucket_name" {
  description = "Name of the access logs bucket"
  value       = var.enable_access_logging ? aws_s3_bucket.access_logs[0].id : null
}
