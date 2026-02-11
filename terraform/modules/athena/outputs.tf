output "athena_workgroup_name" {
  description = "Name of the Athena workgroup"
  value       = aws_athena_workgroup.data_analytics.name
}

output "athena_workgroup_arn" {
  description = "ARN of the Athena workgroup"
  value       = aws_athena_workgroup.data_analytics.arn
}

output "glue_database_name" {
  description = "Name of the Glue Data Catalog database"
  value       = aws_glue_catalog_database.data_lake.name
}

output "glue_table_name" {
  description = "Name of the weather data table"
  value       = aws_glue_catalog_table.weather_data.name
}

output "glue_crawler_name" {
  description = "Name of the Glue crawler"
  value       = aws_glue_crawler.weather_data.name
}

output "athena_results_bucket" {
  description = "S3 bucket for Athena query results"
  value       = aws_s3_bucket.athena_results.bucket
}

output "query_example" {
  description = "Example Athena query to get started"
  value       = <<-EOT
    -- Query weather data with partition filter
    SELECT 
      sensor_id,
      date,
      temperature_avg,
      temp_category,
      precipitation_level,
      data_quality_score
    FROM ${aws_glue_catalog_database.data_lake.name}.${aws_glue_catalog_table.weather_data.name}
    WHERE date >= '2026-02-01'
    ORDER BY date DESC, sensor_id
    LIMIT 100;
  EOT
}
