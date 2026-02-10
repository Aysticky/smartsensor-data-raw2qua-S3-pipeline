variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment (dev, prod)"
  type        = string
}

variable "state_machine_arn" {
  description = "ARN of the Step Functions state machine to trigger"
  type        = string
}

variable "schedule_expression" {
  description = "Cron or rate expression for schedule"
  type        = string
  default     = "cron(0 2 * * ? *)"  # 2 AM UTC daily
}

variable "schedule_enabled" {
  description = "Enable or disable the schedule"
  type        = bool
  default     = true
}

variable "default_start_date" {
  description = "Default start date for extraction (yesterday)"
  type        = string
  default     = "yesterday"
}

variable "default_end_date" {
  description = "Default end date for extraction (yesterday)"
  type        = string
  default     = "yesterday"
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

variable "dlq_arn" {
  description = "ARN of the Dead Letter Queue for failed events"
  type        = string
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
