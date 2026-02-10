# Step Functions State Machine for Job Orchestration
#
# ORCHESTRATION PATTERN:
# 1. Check Job → Validates API connectivity
# 2. Branch on success/failure
# 3. If success → Extract Job
# 4. Log history to S3
#
# WHY STEP FUNCTIONS:
# - Visual workflow tracking
# - Built-in error handling and retries
# - State persistence (know exactly where failure occurred)
# - Easy to add new steps (e.g., data quality checks, notifications)
#
# PRODUCTION CONSIDERATIONS:
# - Standard vs Express workflows:
#   * Standard: Up to 1 year execution, full audit trail, $0.025 per 1000 transitions
#   * Express: < 5 min execution, higher throughput, $1 per 1M requests
# - For daily batch: Use Standard (better audit trail)
# - For real-time streaming: Use Express
#
# MONITORING & ALERTING:
# - Set CloudWatch alarms on ExecutionsFailed metric
# - Track ExecutionTime for performance regression
# - Monitor Throttled transitions (indicates rate limiting)

# IAM role for Step Functions
data "aws_iam_policy_document" "sfn_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn_execution" {
  name               = "${var.project_name}-${var.environment}-sfn-execution"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume_role.json

  tags = merge(
    var.common_tags,
    {
      Name    = "${var.project_name}-${var.environment}-sfn-execution"
      Purpose = "Step Functions execution role"
    }
  )
}

# Policy to allow Step Functions to start Glue jobs
data "aws_iam_policy_document" "sfn_glue_access" {
  statement {
    sid = "GlueJobExecution"
    actions = [
      "glue:StartJobRun",
      "glue:GetJobRun",
      "glue:GetJobRuns",
      "glue:BatchStopJobRun",
    ]
    resources = [
      var.check_job_arn,
      var.extract_job_arn,
    ]
  }
}

resource "aws_iam_policy" "sfn_glue_access" {
  name        = "${var.project_name}-${var.environment}-sfn-glue-access"
  description = "Allow Step Functions to manage Glue jobs"
  policy      = data.aws_iam_policy_document.sfn_glue_access.json
}

resource "aws_iam_role_policy_attachment" "sfn_glue_access" {
  role       = aws_iam_role.sfn_execution.name
  policy_arn = aws_iam_policy.sfn_glue_access.arn
}

# CloudWatch Logs for Step Functions
data "aws_iam_policy_document" "sfn_cloudwatch_logs" {
  statement {
    sid = "CloudWatchLogsAccess"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "sfn_cloudwatch_logs" {
  name        = "${var.project_name}-${var.environment}-sfn-cloudwatch-logs"
  description = "CloudWatch Logs access for Step Functions"
  policy      = data.aws_iam_policy_document.sfn_cloudwatch_logs.json
}

resource "aws_iam_role_policy_attachment" "sfn_cloudwatch_logs" {
  role       = aws_iam_role.sfn_execution.name
  policy_arn = aws_iam_policy.sfn_cloudwatch_logs.arn
}

# Step Functions State Machine definition
resource "aws_sfn_state_machine" "pipeline" {
  name     = "${var.project_name}-${var.environment}-pipeline"
  role_arn = aws_iam_role.sfn_execution.arn

  definition = jsonencode({
    Comment = "Data pipeline: Check API → Extract data"
    StartAt = "CheckAPI"
    States = {
      CheckAPI = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = var.check_job_name
          Arguments = {
            "--execution_id.$" = "$$.Execution.Name"
          }
        }
        ResultPath = "$.checkResult"
        Next       = "CheckSuccess"
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.errorInfo"
            Next        = "CheckFailed"
          }
        ]
        # RETRY STRATEGY:
        # - Check job failures are often transient (network, API rate limits)
        # - Retry 3 times with exponential backoff
        # - Don't retry on validation errors (wrong credentials)
        Retry = [
          {
            ErrorEquals     = ["States.TaskFailed"]
            IntervalSeconds = 60
            MaxAttempts     = 3
            BackoffRate     = 2.0
          }
        ]
      }

      CheckSuccess = {
        Type = "Pass"
        Result = {
          status  = "check_passed"
          message = "API connectivity validated"
        }
        ResultPath = "$.checkStatus"
        Next       = "ExtractData"
      }

      CheckFailed = {
        Type = "Fail"
        Cause = "API check failed"
        Error = "CheckJobError"
        # FAILURE HANDLING:
        # - Send SNS notification to on-call team
        # - Log to CloudWatch for analysis
        # - Don't proceed to extract if check fails
      }

      ExtractData = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = var.extract_job_name
          Arguments = {
            "--execution_id.$"   = "$$.Execution.Name"
            "--check_run_id.$"   = "$.checkResult.Id"
            "--START_DATE.$"     = "$.input.start_date"
            "--END_DATE.$"       = "$.input.end_date"
            "--LATITUDE.$"       = "$.input.latitude"
            "--LONGITUDE.$"      = "$.input.longitude"
          }
        }
        ResultPath = "$.extractResult"
        Next       = "LogSuccess"
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.errorInfo"
            Next        = "ExtractFailed"
          }
        ]
        # EXTRACT JOB RETRY:
        # - Only retry on transient errors (OutOfMemory, S3 throttling)
        # - Don't retry on data quality issues
        Retry = [
          {
            ErrorEquals     = ["States.TaskFailed"]
            IntervalSeconds = 120
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]
      }

      LogSuccess = {
        Type = "Pass"
        Result = {
          status    = "success"
          timestamp = "$.extractResult.CompletedOn"
          message   = "Pipeline completed successfully"
        }
        End = true
      }

      ExtractFailed = {
        Type = "Fail"
        Cause = "Data extraction failed"
        Error = "ExtractJobError"
        # FAILURE SCENARIOS TO WATCH:
        # 1. OutOfMemory → Increase Glue DPUs
        # 2. S3 403 Access Denied → Check IAM permissions
        # 3. API timeout → Implement pagination/chunking
        # 4. Data quality issues → Add validation step
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn_logs.arn}:*"
    include_execution_data = true
    level                  = "ALL"  # ALL, ERROR, FATAL, OFF
  }

  tags = merge(
    var.common_tags,
    {
      Name    = "${var.project_name}-${var.environment}-pipeline"
      Purpose = "Orchestrate check and extract jobs"
    }
  )
}

# CloudWatch Log Group for Step Functions
resource "aws_cloudwatch_log_group" "sfn_logs" {
  name              = "/aws/stepfunctions/${var.project_name}-${var.environment}-pipeline"
  retention_in_days = var.log_retention_days

  tags = merge(
    var.common_tags,
    {
      Name    = "${var.project_name}-${var.environment}-sfn-logs"
      Purpose = "Step Functions execution logs"
    }
  )
}

# OPERATIONAL INSIGHTS:
#
# 1. When to add SNS notifications:
#    - CheckFailed state → Immediate alert (API down)
#    - ExtractFailed state → Alert with execution details
#    - LogSuccess → Optional success notification (for audit)
#
# 2. Adding data quality checks:
#    - Insert new state after ExtractData
#    - Run lightweight Glue job to validate row counts, schemas
#    - Branch to DQFailed or LogSuccess
#
# 3. Handling long-running extracts:
#    - If extract takes > 1 hour, consider:
#      * Breaking into smaller date ranges
#      * Using Map state for parallel processing
#      * Implementing checkpointing within the extract job
#
# 4. Cost optimization:
#    - Monitor state transitions count
#    - Consolidate small tasks into single Glue job
#    - Use Express workflows if latency < 5 min
#
# 5. What changes over time as platform engineer:
#    - Adding new data sources → New parallel branches
#    - Implementing retry strategies based on failure patterns
#    - Tuning timeout values based on historical data
#    - Adding circuit breakers for flaky APIs
