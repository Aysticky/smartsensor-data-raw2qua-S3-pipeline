variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment (dev/prod)"
  type        = string
}

variable "data_bucket_name" {
  description = "S3 bucket containing the data lake"
  type        = string
}

variable "raw_data_prefix" {
  description = "Prefix for raw data in S3"
  type        = string
  default     = "raw/"
}

variable "glue_crawler_role_arn" {
  description = "ARN of IAM role for Glue crawler"
  type        = string
}

variable "crawler_enabled" {
  description = "Enable crawler schedule"
  type        = bool
  default     = false
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
