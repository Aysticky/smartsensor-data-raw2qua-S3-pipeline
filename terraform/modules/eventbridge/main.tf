# EventBridge Scheduler for Daily Pipeline Execution
#
# SCHEDULING STRATEGY:
# - Daily execution at configured time
# - Use cron expressions for precise control
# - Consider time zones (UTC vs local time)
#
# PRODUCTION CONSIDERATIONS:
# 1. Schedule timing:
#    - Run after source data is available (e.g., 2 AM UTC)
#    - Avoid peak business hours for cost optimization
#    - Leave buffer for retries before business day starts
#
# 2. Concurrent executions:
#    - Set max_event_age_in_seconds to prevent stale events
#    - Set retry_attempts based on failure patterns
#    - Monitor for schedule drift (execution delays)
#
# 3. Cost implications:
#    - EventBridge is cheap ($1 per million events)
#    - But accidental frequent triggers can run up Glue costs
#    - Use tags to track costs per environment
#
# OPERATIONAL ISSUES TO WATCH:
# - Clock drift: Ensure Lambda/Glue jobs complete before next trigger
# - Failed invocations: Check IAM permissions and rate limits
# - Missed schedules: Monitor Invocations metric in CloudWatch

# EventBridge rule for daily execution
resource "aws_cloudwatch_event_rule" "daily_pipeline" {
  name                = "${var.project_name}-${var.environment}-daily-pipeline"
  description         = "Trigger data pipeline daily"
  schedule_expression = var.schedule_expression

  is_enabled = var.schedule_enabled

  tags = merge(
    var.common_tags,
    {
      Name    = "${var.project_name}-${var.environment}-daily-pipeline"
      Purpose = "Daily pipeline scheduler"
    }
  )
}

# Target: Step Functions state machine
resource "aws_cloudwatch_event_target" "sfn_pipeline" {
  rule      = aws_cloudwatch_event_rule.daily_pipeline.name
  target_id = "StepFunctionsPipeline"
  arn       = var.state_machine_arn
  role_arn  = aws_iam_role.eventbridge_sfn.arn

  # Input for the state machine
  # INCREMENTAL EXTRACTION PATTERN:
  # - Extract yesterday's data by default
  # - Can be overridden manually for backfills
  input = jsonencode({
    input = {
      start_date = var.default_start_date
      end_date   = var.default_end_date
      latitude   = var.default_latitude
      longitude  = var.default_longitude
      triggered_by = "eventbridge-schedule"
      execution_date = "$${time}"
    }
  })

  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 3600  # 1 hour
  }

  dead_letter_config {
    arn = var.dlq_arn
  }
}

# IAM role for EventBridge to invoke Step Functions
data "aws_iam_policy_document" "eventbridge_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eventbridge_sfn" {
  name               = "${var.project_name}-${var.environment}-eventbridge-sfn"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume_role.json

  tags = merge(
    var.common_tags,
    {
      Name    = "${var.project_name}-${var.environment}-eventbridge-sfn"
      Purpose = "EventBridge to Step Functions invocation"
    }
  )
}

# Policy to allow EventBridge to start Step Functions execution
data "aws_iam_policy_document" "eventbridge_sfn_access" {
  statement {
    sid = "StartStepFunctionsExecution"
    actions = [
      "states:StartExecution",
    ]
    resources = [
      var.state_machine_arn,
    ]
  }
}

resource "aws_iam_policy" "eventbridge_sfn_access" {
  name        = "${var.project_name}-${var.environment}-eventbridge-sfn-access"
  description = "Allow EventBridge to start Step Functions execution"
  policy      = data.aws_iam_policy_document.eventbridge_sfn_access.json
}

resource "aws_iam_role_policy_attachment" "eventbridge_sfn_access" {
  role       = aws_iam_role.eventbridge_sfn.name
  policy_arn = aws_iam_policy.eventbridge_sfn_access.arn
}

# CloudWatch alarms for monitoring
resource "aws_cloudwatch_metric_alarm" "failed_invocations" {
  alarm_name          = "${var.project_name}-${var.environment}-eventbridge-failed-invocations"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FailedInvocations"
  namespace           = "AWS/Events"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Alert when EventBridge fails to invoke Step Functions"
  treat_missing_data  = "notBreaching"

  dimensions = {
    RuleName = aws_cloudwatch_event_rule.daily_pipeline.name
  }

  tags = var.common_tags
}

# INSIGHTS:
#
# 1. Why separate DLQ (Dead Letter Queue):
#    - Failed events go to SQS for manual inspection
#    - Prevents silent failures
#    - Can replay events after fixing issues
#
# 2. Schedule expression examples:
#    - cron(0 2 * * ? *) = 2 AM UTC daily
#    - cron(0 14 ? * MON-FRI *) = 2 PM UTC weekdays only
#    - rate(1 day) = Every 24 hours (simpler but less control)
#
# 3. When to use EventBridge vs Glue triggers:
#    - EventBridge: Complex orchestration, multiple targets
#    - Glue triggers: Simple job-to-job dependencies
#    - Step Functions: Best for multi-step workflows with branching
#
# 4. Handling time zones:
#    - EventBridge uses UTC by default
#    - For local time, calculate offset in cron expression
#    - Example: 2 AM EST = cron(0 7 * * ? *) UTC
#
# 5. What changes over time:
#    - Adjusting schedule based on data availability patterns
#    - Adding multiple schedules for different data sources
#    - Implementing dynamic schedules based on upstream dependencies
#    - Setting up maintenance windows (pause schedules during deployments)
