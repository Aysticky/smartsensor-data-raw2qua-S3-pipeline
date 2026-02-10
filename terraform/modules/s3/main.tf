# S3 Module for Data Lake Storage
# 
# NOTE:
# - Versioning is enabled for data recovery (critical for production)
# - Lifecycle policies manage costs by transitioning old partitions to cheaper storage
# - Server-side encryption is mandatory for compliance
# - Access logging tracks who accesses what (audit trail)
#
# MONITORING CONSIDERATIONS:
# - Set up CloudWatch metrics for bucket size growth
# - Alert on unexpected spike in PUT requests (API issues or loops)
# - Monitor GetObject 403 errors (IAM permission issues)

resource "aws_s3_bucket" "data_lake" {
  bucket = "${var.project_name}-${var.environment}-${var.bucket_suffix}"

  tags = merge(
    var.common_tags,
    {
      Name        = "${var.project_name}-${var.environment}-data-lake"
      Purpose     = "Raw and qualified data storage"
      DataClass   = "Sensitive"
    }
  )
}

# Versioning for data protection
resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

# Server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_id != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_id
    }
    bucket_key_enabled = var.kms_key_id != null ? true : false
  }
}

# Block public access (security best practice)
resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle policy for cost optimization
# COST MANAGEMENT NOTE:
# - Moves data to Glacier after 90 days (adjust based on query patterns)
# - Deletes old data after retention period
# - Incomplete multipart uploads are cleaned up (prevents cost leaks)
resource "aws_s3_bucket_lifecycle_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    id     = "transition-old-data"
    status = "Enabled"

    filter {
      prefix = "raw/"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = var.data_retention_days
    }
  }

  rule {
    id     = "clean-incomplete-uploads"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Access logging bucket
resource "aws_s3_bucket" "access_logs" {
  count  = var.enable_access_logging ? 1 : 0
  bucket = "${var.project_name}-${var.environment}-access-logs"

  tags = merge(
    var.common_tags,
    {
      Name    = "${var.project_name}-${var.environment}-access-logs"
      Purpose = "S3 access audit logs"
    }
  )
}

resource "aws_s3_bucket_logging" "data_lake" {
  count  = var.enable_access_logging ? 1 : 0
  bucket = aws_s3_bucket.data_lake.id

  target_bucket = aws_s3_bucket.access_logs[0].id
  target_prefix = "data-lake-logs/"
}
