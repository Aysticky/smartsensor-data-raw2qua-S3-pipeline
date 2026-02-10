# IAM Roles and Policies for AWS Glue
#
# SECURITY CONSIDERATIONS:
# - Principle of least privilege: Only grant necessary permissions
# - Separate roles for check and extract jobs if they need different permissions
# - Use resource-based constraints (specific S3 paths, not *)
# - Enable CloudTrail to audit role assumption and API calls
#
# OPERATIONAL NOTES:
# - If jobs start failing with Access Denied, check:
#   1. S3 bucket policy doesn't conflict with IAM policy
#   2. KMS key policy allows Glue to use the key
#   3. VPC endpoint policies if using private networking
# - Session duration: Default 1 hour, extend if jobs run longer

# Trust policy for Glue service
data "aws_iam_policy_document" "glue_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}

# Main Glue execution role
resource "aws_iam_role" "glue_execution" {
  name               = "${var.project_name}-${var.environment}-glue-execution"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = merge(
    var.common_tags,
    {
      Name    = "${var.project_name}-${var.environment}-glue-execution"
      Purpose = "Glue job execution role"
    }
  )
}

# AWS managed policy for Glue service
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Custom policy for S3 access
data "aws_iam_policy_document" "glue_s3_access" {
  # Read/Write to data lake bucket
  statement {
    sid = "DataLakeBucketAccess"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      var.data_bucket_arn,
      "${var.data_bucket_arn}/*",
    ]
  }

  # Read from scripts bucket (where Glue job code is stored)
  statement {
    sid = "GlueScriptsBucketAccess"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      var.scripts_bucket_arn,
      "${var.scripts_bucket_arn}/*",
    ]
  }

  # COST OPTIMIZATION NOTE:
  # List operations can be expensive with millions of objects
  # Consider using S3 Inventory instead of ListBucket for large datasets
}

resource "aws_iam_policy" "glue_s3_access" {
  name        = "${var.project_name}-${var.environment}-glue-s3-access"
  description = "S3 access for Glue jobs"
  policy      = data.aws_iam_policy_document.glue_s3_access.json
}

resource "aws_iam_role_policy_attachment" "glue_s3_access" {
  role       = aws_iam_role.glue_execution.name
  policy_arn = aws_iam_policy.glue_s3_access.arn
}

# CloudWatch Logs access for job logging
data "aws_iam_policy_document" "glue_cloudwatch_logs" {
  statement {
    sid = "CloudWatchLogsAccess"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws-glue/*",
    ]
  }

  # MONITORING NOTE:
  # Glue creates log groups automatically, but you should:
  # - Set retention policies (default is never expire = cost risk)
  # - Create metric filters for errors and warnings
  # - Set up alarms for job failures
}

resource "aws_iam_policy" "glue_cloudwatch_logs" {
  name        = "${var.project_name}-${var.environment}-glue-cloudwatch-logs"
  description = "CloudWatch Logs access for Glue jobs"
  policy      = data.aws_iam_policy_document.glue_cloudwatch_logs.json
}

resource "aws_iam_role_policy_attachment" "glue_cloudwatch_logs" {
  role       = aws_iam_role.glue_execution.name
  policy_arn = aws_iam_policy.glue_cloudwatch_logs.arn
}

# Secrets Manager access for API credentials
data "aws_iam_policy_document" "glue_secrets_manager" {
  statement {
    sid = "SecretsManagerAccess"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.project_name}/${var.environment}/*",
    ]
  }

  # SECURITY NOTE:
  # - Rotate API credentials regularly (use Secrets Manager rotation)
  # - Use resource-based policy on secrets for additional control
  # - Monitor GetSecretValue calls in CloudTrail for unusual patterns
}

resource "aws_iam_policy" "glue_secrets_manager" {
  name        = "${var.project_name}-${var.environment}-glue-secrets-manager"
  description = "Secrets Manager access for API credentials"
  policy      = data.aws_iam_policy_document.glue_secrets_manager.json
}

resource "aws_iam_role_policy_attachment" "glue_secrets_manager" {
  role       = aws_iam_role.glue_execution.name
  policy_arn = aws_iam_policy.glue_secrets_manager.arn
}

# DynamoDB access for checkpoint management (optional)
data "aws_iam_policy_document" "glue_dynamodb" {
  count = var.enable_dynamodb_checkpoint ? 1 : 0

  statement {
    sid = "DynamoDBCheckpointAccess"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
    ]
    resources = [
      "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/${var.project_name}-${var.environment}-checkpoint",
    ]
  }

  # CHECKPOINT STRATEGY NOTE:
  # - DynamoDB for small, transactional checkpoint data (cursor, last run time)
  # - S3 for large checkpoint data (partition lists, data quality metrics)
  # - DynamoDB has read/write capacity costs, plan for burst patterns
}

resource "aws_iam_policy" "glue_dynamodb" {
  count       = var.enable_dynamodb_checkpoint ? 1 : 0
  name        = "${var.project_name}-${var.environment}-glue-dynamodb"
  description = "DynamoDB access for checkpoint management"
  policy      = data.aws_iam_policy_document.glue_dynamodb[0].json
}

resource "aws_iam_role_policy_attachment" "glue_dynamodb" {
  count      = var.enable_dynamodb_checkpoint ? 1 : 0
  role       = aws_iam_role.glue_execution.name
  policy_arn = aws_iam_policy.glue_dynamodb[0].arn
}
