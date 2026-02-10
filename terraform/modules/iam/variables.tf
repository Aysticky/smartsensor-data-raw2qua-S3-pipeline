variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment (dev, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "data_bucket_arn" {
  description = "ARN of the data lake S3 bucket"
  type        = string
}

variable "scripts_bucket_arn" {
  description = "ARN of the Glue scripts S3 bucket"
  type        = string
}

variable "enable_dynamodb_checkpoint" {
  description = "Enable DynamoDB for checkpoint management"
  type        = bool
  default     = true
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
