# Development Environment Configuration
#
# PURPOSE: Dev environment for testing and development
# - Lower capacity (cost optimization)
# - More verbose logging
# - Shorter data retention
# - Can be destroyed and recreated frequently

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Backend configuration for state management
  # IMPORTANT: Create this bucket manually before running terraform init
  backend "s3" {
    bucket         = "smartsensors-terraform-state-dev"
    key            = "raw2qua-pipeline/terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    dynamodb_table = "smartsensors-terraform-locks-dev"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "SmartSensor Data Pipeline"
      Environment = "dev"
      ManagedBy   = "Terraform"
      Repository  = "smartsensor-data-raw2qua-S3-pipeline"
      CostCenter  = "DataEngineering"
    }
  }
}

# Get current AWS account info
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  project_name   = "smartsensors"
  environment    = "dev"
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_region     = data.aws_region.current.name

  common_tags = {
    Project     = "SmartSensor Data Pipeline"
    Environment = "dev"
    ManagedBy   = "Terraform"
  }
}

# Dead Letter Queue for failed EventBridge events
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.project_name}-${local.environment}-pipeline-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = local.common_tags
}

# S3 Module
module "s3" {
  source = "../../modules/s3"

  project_name          = local.project_name
  environment           = local.environment
  bucket_suffix         = "raw-data-${local.aws_account_id}"
  enable_versioning     = true
  data_retention_days   = 90    # Dev: shorter retention
  enable_access_logging = false # Dev: disable to save costs
  common_tags           = local.common_tags
}

# IAM Module (depends on S3 for bucket ARNs)
module "iam" {
  source = "../../modules/iam"

  project_name               = local.project_name
  environment                = local.environment
  aws_region                 = local.aws_region
  aws_account_id             = local.aws_account_id
  data_bucket_arn            = module.s3.bucket_arn
  scripts_bucket_arn         = module.glue.scripts_bucket_arn
  enable_dynamodb_checkpoint = true # Enable DynamoDB checkpoints
  common_tags                = local.common_tags
}

# Glue Module
module "glue" {
  source = "../../modules/glue"

  project_name        = local.project_name
  environment         = local.environment
  glue_role_arn       = module.iam.glue_execution_role_arn
  glue_version        = "4.0"
  data_bucket_name    = module.s3.bucket_name
  extract_worker_type = "G.1X"
  extract_num_workers = 2 # Dev: minimal workers
  default_start_date  = "2026-02-01"
  default_end_date    = "2026-02-10"
  checkpoint_table_name = module.dynamodb.table_name
  use_incremental     = true # Enable incremental processing
  common_tags         = local.common_tags
}

# Step Functions Module
module "stepfunctions" {
  source = "../../modules/stepfunctions"

  project_name       = local.project_name
  environment        = local.environment
  check_job_name     = module.glue.check_job_name
  check_job_arn      = module.glue.check_job_arn
  extract_job_name   = module.glue.extract_job_name
  extract_job_arn    = module.glue.extract_job_arn
  log_retention_days = 7 # Dev: shorter retention
  common_tags        = local.common_tags
}

# EventBridge Module
module "eventbridge" {
  source = "../../modules/eventbridge"

  project_name        = local.project_name
  environment         = local.environment
  state_machine_arn   = module.stepfunctions.state_machine_arn
  schedule_expression = "cron(0 3 * * ? *)" # 3 AM UTC daily (dev runs later)
  schedule_enabled    = false               # Dev: manual triggers only by default
  dlq_arn             = aws_sqs_queue.dlq.arn
  common_tags         = local.common_tags
}

# Athena Module
module "athena" {
  source = "../../modules/athena"

  project_name           = local.project_name
  environment            = local.environment
  data_bucket_name       = module.s3.bucket_name
  raw_data_prefix        = "raw/"
  glue_crawler_role_arn  = module.iam.glue_execution_role_arn
  crawler_enabled        = false # Dev: manual crawler runs
  common_tags            = local.common_tags
}

# DynamoDB Module (for incremental checkpointing)
module "dynamodb" {
  source = "../../modules/dynamodb"

  project_name         = local.project_name
  environment          = local.environment
  enable_pitr          = false # Dev: no point-in-time recovery
  initial_start_date   = "2026-01-01"
  common_tags          = local.common_tags
}
