variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment (dev, prod)"
  type        = string
}

variable "glue_role_arn" {
  description = "ARN of the Glue execution role"
  type        = string
}

variable "glue_version" {
  description = "Glue version (4.0, 5.0)"
  type        = string
  default     = "4.0"
}

variable "data_bucket_name" {
  description = "Name of the data lake bucket"
  type        = string
}

variable "api_endpoint" {
  description = "API endpoint URL"
  type        = string
  default     = "https://archive-api.open-meteo.com/v1/archive"
}

variable "extract_worker_type" {
  description = "Worker type for extract job (G.1X, G.2X)"
  type        = string
  default     = "G.1X"
}

variable "extract_num_workers" {
  description = "Number of workers for extract job"
  type        = number
  default     = 2
}

variable "default_start_date" {
  description = "Default start date for data extraction"
  type        = string
  default     = "2026-02-01"
}

variable "default_end_date" {
  description = "Default end date for data extraction"
  type        = string
  default     = "2026-02-10"
}

variable "default_latitude" {
  description = "Default latitude for weather data"
  type        = string
  default     = "52.3676"
}

variable "default_longitude" {
  description = "Default longitude for weather data"
  type        = string
  default     = "4.9041"
}

variable "checkpoint_table_name" {
  description = "DynamoDB table name for checkpoints (optional)"
  type        = string
  default     = ""
}

variable "use_incremental" {
  description = "Enable incremental processing with checkpoints"
  type        = bool
  default     = false
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
