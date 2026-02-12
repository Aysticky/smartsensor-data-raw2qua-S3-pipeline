# AWS Athena Module for Querying Data Lake
#
# ATHENA ARCHITECTURE:
# - Serverless SQL query engine on S3 data
# - Uses Glue Data Catalog for metadata
# - Queries Parquet files with Snappy compression
# - Results stored in S3 query results bucket
#
# COST OPTIMIZATION:
# - $5 per TB scanned (not stored)
# - Partition pruning reduces scanned data
# - Columnar format (Parquet) reduces costs
# - Compress data before querying
#
# BEST PRACTICES:
# 1. Always partition data (by date, region, etc.)
# 2. Use columnar formats (Parquet, ORC)
# 3. Compress files (Snappy, GZIP)
# 4. Use workgroups for cost tracking
# 5. Set query result retention policies

# S3 bucket for Athena query results
resource "aws_s3_bucket" "athena_results" {
  bucket = "${var.project_name}-${var.environment}-athena-results"

  tags = merge(
    var.common_tags,
    {
      Name    = "${var.project_name}-${var.environment}-athena-results"
      Purpose = "Athena query results storage"
    }
  )
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "cleanup_old_results"
    status = "Enabled"

    expiration {
      days = 7 # Delete query results after 7 days
    }
  }
}

# Glue Data Catalog Database
resource "aws_glue_catalog_database" "data_lake" {
  name        = "${var.project_name}_${var.environment}_data_lake"
  description = "Data lake catalog for ${var.project_name} ${var.environment}"

  tags = merge(
    var.common_tags,
    {
      Name        = "${var.project_name}-${var.environment}-catalog"
      Environment = var.environment
    }
  )
}

# Glue Catalog Table for weather data
resource "aws_glue_catalog_table" "weather_data" {
  name          = "weather_data_raw"
  database_name = aws_glue_catalog_database.data_lake.name
  description   = "Raw weather data from OpenMeteo API"

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification"      = "parquet"
    "compressionType"     = "snappy"
    "typeOfData"          = "file"
    "parquet.compression" = "SNAPPY"
    "projection.enabled"  = "false"
  }

  storage_descriptor {
    location      = "s3://${var.data_bucket_name}/${var.raw_data_prefix}openmeteo/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "ParquetHiveSerDe"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"

      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name    = "sensor_id"
      type    = "string"
      comment = "Unique sensor identifier"
    }

    columns {
      name    = "region"
      type    = "string"
      comment = "Geographic region"
    }

    columns {
      name    = "latitude"
      type    = "double"
      comment = "Sensor latitude"
    }

    columns {
      name    = "longitude"
      type    = "double"
      comment = "Sensor longitude"
    }

    columns {
      name    = "temperature_max"
      type    = "double"
      comment = "Maximum temperature (Celsius)"
    }

    columns {
      name    = "temperature_min"
      type    = "double"
      comment = "Minimum temperature (Celsius)"
    }

    columns {
      name    = "precipitation"
      type    = "double"
      comment = "Total precipitation (mm)"
    }

    columns {
      name    = "source"
      type    = "string"
      comment = "Data source (open-meteo)"
    }

    columns {
      name    = "ingestion_timestamp"
      type    = "string"
      comment = "When data was ingested"
    }

    columns {
      name    = "temperature_max_f"
      type    = "double"
      comment = "Maximum temperature (Fahrenheit)"
    }

    columns {
      name    = "temperature_min_f"
      type    = "double"
      comment = "Minimum temperature (Fahrenheit)"
    }

    columns {
      name    = "temperature_avg"
      type    = "double"
      comment = "Average temperature (Celsius)"
    }

    columns {
      name    = "temperature_range"
      type    = "double"
      comment = "Temperature range (max - min)"
    }

    columns {
      name    = "temp_category"
      type    = "string"
      comment = "Temperature category (freezing/cold/mild/warm/hot)"
    }

    columns {
      name    = "precipitation_level"
      type    = "string"
      comment = "Precipitation level (none/light/moderate/heavy/extreme)"
    }

    columns {
      name    = "is_complete"
      type    = "boolean"
      comment = "Data completeness flag"
    }

    columns {
      name    = "data_quality_score"
      type    = "int"
      comment = "Data quality score (0-100)"
    }

    columns {
      name    = "region_avg_temp"
      type    = "double"
      comment = "Regional average temperature"
    }

    columns {
      name    = "region_total_precipitation"
      type    = "double"
      comment = "Regional total precipitation"
    }

    columns {
      name    = "processed_at"
      type    = "string"
      comment = "Processing timestamp"
    }

    columns {
      name    = "processing_version"
      type    = "string"
      comment = "ETL processing version"
    }
  }

  partition_keys {
    name    = "dt"
    type    = "string"
    comment = "Partition by date (YYYY-MM-DD)"
  }
}

# Athena Workgroup for query execution
resource "aws_athena_workgroup" "data_analytics" {
  name        = "${var.project_name}-${var.environment}-analytics"
  description = "Workgroup for data analytics queries"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/query-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }

  tags = merge(
    var.common_tags,
    {
      Name        = "${var.project_name}-${var.environment}-analytics"
      Environment = var.environment
    }
  )
}

# Glue Crawler to auto-discover partitions
resource "aws_glue_crawler" "weather_data" {
  name          = "${var.project_name}-${var.environment}-weather-crawler"
  role          = var.glue_crawler_role_arn
  database_name = aws_glue_catalog_database.data_lake.name
  description   = "Crawler to discover new partitions in weather data"

  s3_target {
    path = "s3://${var.data_bucket_name}/${var.raw_data_prefix}openmeteo/"
  }

  schedule = var.crawler_enabled ? "cron(0 4 * * ? *)" : null # 4 AM UTC daily

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "LOG"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = {
        AddOrUpdateBehavior = "InheritFromTable"
      }
    }
  })

  tags = merge(
    var.common_tags,
    {
      Name        = "${var.project_name}-${var.environment}-weather-crawler"
      Environment = var.environment
    }
  )
}
