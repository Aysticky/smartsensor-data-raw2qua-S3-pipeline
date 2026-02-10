# Production Environment Configuration
#
# PURPOSE: Production environment for live data processing
# - Higher capacity and redundancy
# - Comprehensive monitoring and alerting
# - Longer data retention for compliance
# - Change control required (no ad-hoc modifications)

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "smartsensors-terraform-state-prod"
    key            = "raw2qua-pipeline/terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    dynamodb_table = "smartsensors-terraform-locks-prod"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SmartSensor Data Pipeline"
      Environment = "prod"
      ManagedBy   = "Terraform"
      Repository  = "smartsensor-data-raw2qua-S3-pipeline"
      CostCenter  = "DataEngineering"
      Compliance  = "Required"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  project_name   = "smartsensors"
  environment    = "prod"
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_region     = data.aws_region.current.name

  common_tags = {
    Project     = "SmartSensor Data Pipeline"
    Environment = "prod"
    ManagedBy   = "Terraform"
    Compliance  = "Required"
  }
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.project_name}-${local.environment}-pipeline-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = local.common_tags
}

module "s3" {
  source = "../../modules/s3"

  project_name          = local.project_name
  environment           = local.environment
  bucket_suffix         = "raw-data-${local.aws_account_id}"
  enable_versioning     = true
  data_retention_days   = 365  # Prod: longer retention
  enable_access_logging = true # Prod: enable audit logging
  common_tags           = local.common_tags
}

module "iam" {
  source = "../../modules/iam"

  project_name               = local.project_name
  environment                = local.environment
  aws_region                 = local.aws_region
  aws_account_id             = local.aws_account_id
  data_bucket_arn            = module.s3.bucket_arn
  scripts_bucket_arn         = module.glue.scripts_bucket_arn
  enable_dynamodb_checkpoint = true # Prod: use DynamoDB for reliability
  common_tags                = local.common_tags
}

module "glue" {
  source = "../../modules/glue"

  project_name        = local.project_name
  environment         = local.environment
  glue_role_arn       = module.iam.glue_execution_role_arn
  glue_version        = "4.0"
  data_bucket_name    = module.s3.bucket_name
  extract_worker_type = "G.1X"
  extract_num_workers = 5 # Prod: more workers for performance
  default_start_date  = "2026-02-01"
  default_end_date    = "2026-02-10"
  common_tags         = local.common_tags
}

module "stepfunctions" {
  source = "../../modules/stepfunctions"

  project_name       = local.project_name
  environment        = local.environment
  check_job_name     = module.glue.check_job_name
  check_job_arn      = module.glue.check_job_arn
  extract_job_name   = module.glue.extract_job_name
  extract_job_arn    = module.glue.extract_job_arn
  log_retention_days = 90 # Prod: longer retention for compliance
  common_tags        = local.common_tags
}

module "eventbridge" {
  source = "../../modules/eventbridge"

  project_name        = local.project_name
  environment         = local.environment
  state_machine_arn   = module.stepfunctions.state_machine_arn
  schedule_expression = "cron(0 2 * * ? *)" # 2 AM UTC daily
  schedule_enabled    = true                # Prod: schedule enabled
  dlq_arn             = aws_sqs_queue.dlq.arn
  common_tags         = local.common_tags
}

# PRODUCTION-SPECIFIC MONITORING
# Add SNS topics, CloudWatch dashboards, and alarms here
