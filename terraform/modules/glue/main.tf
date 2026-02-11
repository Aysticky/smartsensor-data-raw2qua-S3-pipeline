# AWS Glue Jobs Module
#
# GLUE ARCHITECTURE NOTES:
# - We use two separate jobs: check_job and extract_job
# - Check job is lightweight (1 DPU, fast startup)
# - Extract job scales with data volume (configurable DPUs)
#
# PERFORMANCE CONSIDERATIONS:
# - DPU (Data Processing Unit) = 4 vCPU + 16 GB RAM
# - Glue 4.0/5.0 has faster startup than Glue 2.0 (~1 min vs 10 min)
# - Use G.1X workers for memory-intensive operations
# - Use G.2X workers only if you process very large datasets (>100GB)
#
# COST OPTIMIZATION:
# - Check job: Use minimum DPUs (1-2), runs in 1-2 minutes = ~$0.01/run
# - Extract job: Right-size DPUs based on data volume
# - Set max concurrent runs to prevent runaway costs
# - Use job bookmarks to avoid reprocessing data
#
# COMMON ISSUES TO MONITOR:
# 1. OutOfMemory errors → Increase DPUs or optimize Spark code
# 2. Slow job startup → Upgrade to Glue 4.0/5.0
# 3. S3 throttling → Distribute writes across more partitions
# 4. Connection timeouts to APIs → Add retry logic with exponential backoff

# S3 bucket for Glue scripts
resource "aws_s3_bucket" "glue_scripts" {
  bucket = "${var.project_name}-${var.environment}-glue-scripts"

  tags = merge(
    var.common_tags,
    {
      Name    = "${var.project_name}-${var.environment}-glue-scripts"
      Purpose = "Glue job scripts and dependencies"
    }
  )
}

resource "aws_s3_bucket_versioning" "glue_scripts" {
  bucket = aws_s3_bucket.glue_scripts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Upload Glue job scripts to S3
resource "aws_s3_object" "check_job_script" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "scripts/check_job.py"
  source = "${path.module}/../../../src/glue_jobs/check_job.py"
  etag   = filemd5("${path.module}/../../../src/glue_jobs/check_job.py")

  tags = {
    JobType = "check"
  }
}

resource "aws_s3_object" "extract_job_script" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "scripts/extract_job.py"
  source = "${path.module}/../../../src/glue_jobs/extract_job.py"
  etag   = filemd5("${path.module}/../../../src/glue_jobs/extract_job.py")

  tags = {
    JobType = "extract"
  }
}

# Upload transformations module
resource "aws_s3_object" "transformations_module" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "scripts/transformations.py"
  source = "${path.module}/../../../src/glue_jobs/transformations.py"
  etag   = filemd5("${path.module}/../../../src/glue_jobs/transformations.py")

  tags = {
    JobType = "module"
  }
}

# Glue Job: Check API availability
resource "aws_glue_job" "check_api" {
  name     = "${var.project_name}-${var.environment}-check-api"
  role_arn = var.glue_role_arn

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.id}/scripts/check_job.py"
    python_version  = "3"
  }

  glue_version = var.glue_version

  # Lightweight job configuration
  max_capacity = 1.0 # Minimum for simple checks

  # Or use worker_type and number_of_workers for Glue 2.0+
  # worker_type       = "G.1X"
  # number_of_workers = 2

  timeout = 10 # 10 minutes max (should complete in 1-2 minutes)

  max_retries = 1

  default_arguments = {
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${aws_s3_bucket.glue_scripts.id}/spark-logs/"
    "--job-language"                     = "python"
    "--TempDir"                          = "s3://${aws_s3_bucket.glue_scripts.id}/temp/"
    "--enable-job-insights"              = "true"

    # Custom job parameters
    "--API_ENDPOINT"      = var.api_endpoint
    "--SECRETS_NAME"      = "${var.project_name}/${var.environment}/api-credentials"
    "--S3_BUCKET"         = var.data_bucket_name
    "--CHECKPOINT_PREFIX" = "checkpoints/check-job/"
  }

  tags = merge(
    var.common_tags,
    {
      Name    = "${var.project_name}-${var.environment}-check-api"
      JobType = "check"
      Purpose = "Validate API connectivity and authentication"
    }
  )
}

# Glue Job: Extract data from API
resource "aws_glue_job" "extract_data" {
  name     = "${var.project_name}-${var.environment}-extract-data"
  role_arn = var.glue_role_arn

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.id}/scripts/extract_job.py"
    python_version  = "3"
  }

  glue_version = var.glue_version

  # Scalable job configuration
  worker_type       = var.extract_worker_type
  number_of_workers = var.extract_num_workers

  timeout = 120 # 2 hours max

  max_retries = 2

  # Job bookmarks for incremental processing
  # INCREMENTAL PROCESSING NOTE:
  # - Job bookmarks track processed data to avoid reprocessing
  # - Only works with certain data sources (S3, JDBC, DynamoDB)
  # - For REST APIs, we manage checkpoints manually
  # execution_property {
  #   max_concurrent_runs = 1
  # }

  default_arguments = {
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${aws_s3_bucket.glue_scripts.id}/spark-logs/"
    "--job-language"                     = "python"
    "--TempDir"                          = "s3://${aws_s3_bucket.glue_scripts.id}/temp/"
    "--enable-job-insights"              = "true"
    "--job-bookmark-option"              = "job-bookmark-disable" # We handle checkpoints manually
    "--extra-py-files"                   = "s3://${aws_s3_bucket.glue_scripts.id}/scripts/transformations.py" # Include transformations module

    # Custom job parameters
    "--API_ENDPOINT"      = var.api_endpoint
    "--SECRETS_NAME"      = "${var.project_name}/${var.environment}/api-credentials"
    "--S3_BUCKET"         = var.data_bucket_name
    "--S3_RAW_PREFIX"     = "raw/openmeteo/"
    "--CHECKPOINT_PREFIX" = "checkpoints/extract-job/"
    "--START_DATE"        = var.default_start_date
    "--END_DATE"          = var.default_end_date
    "--CHECKPOINT_TABLE"  = var.checkpoint_table_name
    "--USE_INCREMENTAL"   = tostring(var.use_incremental)
    "--LATITUDE"          = var.default_latitude
    "--LONGITUDE"         = var.default_longitude

    # Spark configuration for optimization
    "--conf" = "spark.sql.adaptive.enabled=true --conf spark.sql.adaptive.coalescePartitions.enabled=true"
  }

  tags = merge(
    var.common_tags,
    {
      Name    = "${var.project_name}-${var.environment}-extract-data"
      JobType = "extract"
      Purpose = "Extract data from REST API and write to S3"
    }
  )
}

# OPERATIONAL MONITORING POINTS:
# 
# 1. Job Duration Trends:
#    - Set CloudWatch alarm if job duration > 2x normal (indicates API slowness or data spike)
#    - Track DPU-hours for cost analysis
#
# 2. Data Quality Checks:
#    - Count rows written vs expected
#    - Check for null values in critical fields
#    - Validate partition creation (dt=YYYY-MM-DD)
#
# 3. API Health:
#    - Monitor HTTP error rates (4xx, 5xx)
#    - Track rate limit hits (HTTP 429)
#    - Measure API response times
#
# 4. Checkpoint Integrity:
#    - Ensure checkpoint updates are atomic
#    - Backup checkpoints before critical updates
#    - Alert if checkpoint is stale (not updated in 24 hours)
#
# 5. S3 Performance:
#    - Monitor S3 request rates (should stay under limits)
#    - Track GetObject/PutObject latencies
#    - Alert on 503 SlowDown errors from S3
