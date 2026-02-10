variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment (dev, prod)"
  type        = string
}

variable "bucket_suffix" {
  description = "Unique suffix for bucket name"
  type        = string
}

variable "enable_versioning" {
  description = "Enable S3 versioning for data recovery"
  type        = bool
  default     = true
}

variable "kms_key_id" {
  description = "KMS key ID for encryption (null for AES256)"
  type        = string
  default     = null
}

variable "data_retention_days" {
  description = "Number of days to retain data before deletion"
  type        = number
  default     = 365
}

variable "enable_access_logging" {
  description = "Enable S3 access logging"
  type        = bool
  default     = true
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
