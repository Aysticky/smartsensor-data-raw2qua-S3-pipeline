variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment (dev, prod)"
  type        = string
}

variable "check_job_name" {
  description = "Name of the check Glue job"
  type        = string
}

variable "check_job_arn" {
  description = "ARN of the check Glue job"
  type        = string
}

variable "extract_job_name" {
  description = "Name of the extract Glue job"
  type        = string
}

variable "extract_job_arn" {
  description = "ARN of the extract Glue job"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
