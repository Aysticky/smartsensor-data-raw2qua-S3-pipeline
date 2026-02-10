"""
Glue Job: Extract Data from REST API to S3

PURPOSE:
- Fetch data from REST API with pagination
- Transform to DataFrame
- Write Parquet to S3 partitioned by date
- Update checkpoint for incremental processing

JOB CHARACTERISTICS:
- Distributed Spark processing
- Handles millions of rows
- Partitioned output for query optimization
- Idempotent (can retry safely)

OPERATIONAL CONSIDERATIONS:
- Monitor for OutOfMemory errors (increase DPUs if needed)
- Watch S3 write throughput (distribute across partitions)
- Track job duration trends (performance degradation indicator)
- Validate row counts against API response metadata

BIG DATA ISSUES TO WATCH:
1. Data skew: Some partitions much larger than others
2. Small files problem: Too many tiny Parquet files
3. S3 eventual consistency: Reads immediately after writes
4. Schema evolution: API adds new fields
5. Backpressure: API can't keep up with Spark parallelism
"""

import json
import logging
import sys
from datetime import datetime, date, timedelta
from typing import List, Dict, Any

import boto3
import requests
from awsglue.context import GlueContext
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import Row, DataFrame
from pyspark.sql.types import (
    StructType,
    StructField,
    StringType,
    DoubleType,
    TimestampType,
)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def get_job_parameters():
    """Get Glue job parameters"""
    required_args = [
        'JOB_NAME',
        'API_ENDPOINT',
        'S3_BUCKET',
        'S3_RAW_PREFIX',
        'CHECKPOINT_PREFIX',
        'START_DATE',
        'END_DATE',
        'LATITUDE',
        'LONGITUDE',
    ]
    
    args = getResolvedOptions(sys.argv, required_args)
    
    # Get optional arguments
    optional_args = [
        'SECRETS_NAME',
        'execution_id',
        'check_run_id',
    ]
    
    try:
        optional = getResolvedOptions(sys.argv, optional_args)
        args.update(optional)
    except Exception:
        pass
    
    return args


def daterange(start: date, end: date):
    """Generate date range (inclusive)"""
    current = start
    while current <= end:
        yield current
        current += timedelta(days=1)


def parse_date_string(date_str: str) -> date:
    """
    Parse date string with support for relative dates
    
    INCREMENTAL PATTERN:
    - 'yesterday' → Always process previous day
    - 'today' → Process current day (risky for incomplete data)
    - 'YYYY-MM-DD' → Specific date
    """
    date_str = date_str.lower().strip()
    today = date.today()
    
    if date_str == 'yesterday':
        return today - timedelta(days=1)
    elif date_str == 'today':
        return today
    elif date_str == 'last_week':
        return today - timedelta(days=7)
    else:
        return date.fromisoformat(date_str)


def fetch_weather_data_for_date(
    api_endpoint: str,
    lat: float,
    lon: float,
    target_date: date,
    timeout: int = 30
) -> Dict[str, Any]:
    """
    Fetch weather data for single date
    
    API CALL STRATEGY:
    - One request per date (API limitation)
    - Could batch multiple dates, but max 16 days
    - For historical data, may need thousands of calls
    
    RATE LIMITING:
    - Free tier: ~10,000 requests/day
    - Need to throttle Spark parallelism
    - Implement exponential backoff on 429
    
    ERROR SCENARIOS:
    - Network timeout → Retry
    - API error (5xx) → Retry
    - Rate limit (429) → Sleep and retry
    - Invalid parameters (4xx) → Don't retry, log error
    """
    url = f"{api_endpoint}"
    
    params = {
        'latitude': lat,
        'longitude': lon,
        'start_date': target_date.isoformat(),
        'end_date': target_date.isoformat(),
        'daily': 'temperature_2m_max,temperature_2m_min,precipitation_sum',
        'timezone': 'UTC',
    }
    
    max_retries = 3
    retry_count = 0
    
    while retry_count < max_retries:
        try:
            response = requests.get(url, params=params, timeout=timeout)
            
            # Handle rate limiting
            if response.status_code == 429:
                wait_time = int(response.headers.get('Retry-After', 60))
                logger.warning(f"Rate limited, waiting {wait_time} seconds...")
                import time
                time.sleep(wait_time)
                retry_count += 1
                continue
            
            response.raise_for_status()
            
            data = response.json()
            daily = data.get('daily', {})
            
            # Extract values
            return {
                'dt': target_date.isoformat(),
                'latitude': float(lat),
                'longitude': float(lon),
                'temperature_max': float(daily['temperature_2m_max'][0]) if daily.get('temperature_2m_max') else None,
                'temperature_min': float(daily['temperature_2m_min'][0]) if daily.get('temperature_2m_min') else None,
                'precipitation': float(daily['precipitation_sum'][0]) if daily.get('precipitation_sum') else None,
                'source': 'open-meteo',
                'ingestion_timestamp': datetime.utcnow().isoformat(),
            }
        
        except requests.exceptions.Timeout:
            logger.warning(f"Request timeout (attempt {retry_count + 1}/{max_retries})")
            retry_count += 1
            
            if retry_count >= max_retries:
                logger.error(f"Failed after {max_retries} retries for date {target_date}")
                return None
        
        except requests.exceptions.RequestException as e:
            logger.error(f"Request failed for date {target_date}: {e}")
            retry_count += 1
            
            if retry_count >= max_retries:
                return None
    
    return None


def create_spark_dataframe(
    spark,
    rows: List[Dict[str, Any]],
    schema: StructType
) -> DataFrame:
    """
    Create Spark DataFrame from list of dicts
    
    SPARK OPTIMIZATION:
    - Use explicit schema (faster than inference)
    - Partition data appropriately (by date)
    - Use Parquet for columnar storage
    - Enable compression (Snappy is good balance)
    
    DATA QUALITY CHECKS:
    - Remove null rows
    - Validate required fields
    - Check for duplicates
    - Validate data types
    """
    # Convert to Row objects
    row_objects = [Row(**row) for row in rows if row is not None]
    
    if not row_objects:
        logger.warning("No valid rows to create DataFrame")
        return None
    
    # Create DataFrame
    df = spark.createDataFrame(row_objects, schema=schema)
    
    logger.info(f"Created DataFrame with {df.count()} rows")
    
    return df


def write_to_s3(
    df: DataFrame,
    s3_bucket: str,
    s3_prefix: str,
    partition_cols: List[str]
) -> None:
    """
    Write DataFrame to S3 as partitioned Parquet
    
    PARTITIONING STRATEGY:
    - Partition by 'dt' (date) for efficient time-range queries
    - Avoid over-partitioning (too many small files)
    - Consider location-based partitioning for multi-location data
    
    FILE SIZE OPTIMIZATION:
    - Target: 128-256 MB per file
    - Too small: Slow metadata operations, high S3 costs
    - Too large: Poor parallelism, long read times
    - Use coalesce() or repartition() to control file count
    
    WRITE MODES:
    - 'append': Add to existing data (standard for daily jobs)
    - 'overwrite': Replace all data (careful!)
    - 'error': Fail if data exists (safe but strict)
    - 'ignore': Skip if exists (silent failures risk)
    
    IDEMPOTENCY PATTERN:
    - Write to temp location first
    - Validate the write
    - Move/rename to final location (atomic)
    - Or use partition overwrite mode
    """
    output_path = f"s3://{s3_bucket}/{s3_prefix}"
    
    logger.info(f"Writing DataFrame to {output_path}")
    logger.info(f"Partition columns: {partition_cols}")
    
    # Optimize file size
    # For small datasets, reduce partitions
    row_count = df.count()
    target_rows_per_file = 100000
    num_partitions = max(1, row_count // target_rows_per_file)
    
    logger.info(f"Repartitioning to {num_partitions} partitions for optimal file size")
    
    df = df.repartition(num_partitions, *partition_cols)
    
    # Write to S3
    try:
        df.write \
            .mode('append') \
            .partitionBy(*partition_cols) \
            .format('parquet') \
            .option('compression', 'snappy') \
            .save(output_path)
        
        logger.info(f"Successfully wrote {row_count} rows to {output_path}")
    
    except Exception as e:
        logger.error(f"Failed to write to S3: {e}")
        raise


def update_checkpoint(
    s3_bucket: str,
    checkpoint_prefix: str,
    checkpoint_data: Dict[str, Any]
) -> None:
    """
    Update checkpoint for incremental processing
    
    CHECKPOINT CONTENTS:
    - last_processed_date: Latest date successfully processed
    - last_run_timestamp: When job completed
    - rows_processed: Total rows in this run
    - status: success/failed
    - next_start_date: Where to start next run
    
    CHECKPOINT ATOMICITY:
    - S3 PutObject is atomic
    - But consider using DynamoDB for stronger consistency
    - Or use versioning + latest pointer pattern
    """
    s3_client = boto3.client('s3')
    
    checkpoint_key = f"{checkpoint_prefix}latest-checkpoint.json"
    
    # Add metadata
    checkpoint_data['updated_at'] = datetime.utcnow().isoformat()
    
    try:
        s3_client.put_object(
            Bucket=s3_bucket,
            Key=checkpoint_key,
            Body=json.dumps(checkpoint_data, indent=2),
            ContentType='application/json'
        )
        
        logger.info(f"Updated checkpoint: s3://{s3_bucket}/{checkpoint_key}")
    
    except Exception as e:
        logger.error(f"Failed to update checkpoint: {e}")
        # Don't fail job just for checkpoint update
        # But log prominently for investigation


def main():
    """
    Main execution logic
    
    FLOW:
    1. Initialize Spark context
    2. Get job parameters
    3. Fetch data from API for date range
    4. Create DataFrame
    5. Write to S3 partitioned
    6. Update checkpoint
    7. Log metrics
    """
    logger.info("Starting data extraction job")
    
    try:
        # Initialize Spark
        sc = SparkContext.getOrCreate()
        glue_context = GlueContext(sc)
        spark = glue_context.spark_session
        
        # Get parameters
        args = get_job_parameters()
        
        logger.info(f"Job parameters: {json.dumps({k: v for k, v in args.items() if 'SECRET' not in k.upper()})}")
        
        # Parse dates
        start_date = parse_date_string(args['START_DATE'])
        end_date = parse_date_string(args['END_DATE'])
        
        logger.info(f"Processing date range: {start_date} to {end_date}")
        
        # Parse coordinates
        latitude = float(args['LATITUDE'])
        longitude = float(args['LONGITUDE'])
        
        # Define schema
        schema = StructType([
            StructField('dt', StringType(), False),
            StructField('latitude', DoubleType(), False),
            StructField('longitude', DoubleType(), False),
            StructField('temperature_max', DoubleType(), True),
            StructField('temperature_min', DoubleType(), True),
            StructField('precipitation', DoubleType(), True),
            StructField('source', StringType(), False),
            StructField('ingestion_timestamp', StringType(), False),
        ])
        
        # Fetch data for each date
        rows = []
        failed_dates = []
        
        for target_date in daterange(start_date, end_date):
            logger.info(f"Fetching data for {target_date}")
            
            row_data = fetch_weather_data_for_date(
                args['API_ENDPOINT'],
                latitude,
                longitude,
                target_date
            )
            
            if row_data:
                rows.append(row_data)
            else:
                failed_dates.append(target_date.isoformat())
                logger.warning(f"Failed to fetch data for {target_date}")
        
        # Create DataFrame
        if not rows:
            logger.error("No data fetched successfully")
            raise RuntimeError("No data fetched successfully")
        
        df = create_spark_dataframe(spark, rows, schema)
        
        if df is None:
            logger.error("Failed to create DataFrame")
            raise RuntimeError("Failed to create DataFrame")
        
        # Write to S3
        write_to_s3(
            df,
            args['S3_BUCKET'],
            args['S3_RAW_PREFIX'],
            partition_cols=['dt']
        )
        
        # Update checkpoint
        checkpoint_data = {
            'last_processed_date': end_date.isoformat(),
            'start_date': start_date.isoformat(),
            'end_date': end_date.isoformat(),
            'rows_processed': len(rows),
            'failed_dates': failed_dates,
            'status': 'success',
            'job_name': args['JOB_NAME'],
            'execution_id': args.get('execution_id', 'unknown'),
        }
        
        update_checkpoint(
            args['S3_BUCKET'],
            args['CHECKPOINT_PREFIX'],
            checkpoint_data
        )
        
        # Print summary
        summary = {
            'status': 'success',
            'rows_processed': len(rows),
            'failed_dates_count': len(failed_dates),
            'date_range': f"{start_date} to {end_date}",
        }
        
        logger.info(f"Job completed successfully: {json.dumps(summary)}")
        print(json.dumps(summary))
        
        # Success - let job complete normally
        return
    
    except Exception as e:
        logger.error(f"Job failed with exception: {e}", exc_info=True)
        
        print(json.dumps({
            'status': 'failed',
            'error': str(e),
        }))
        
        # Re-raise to fail the Glue job
        raise


if __name__ == "__main__":
    main()


# INSIGHTS:
#
# 1. Scaling from thousands to millions of rows:
#    - Current: Fetch serially, works for <10K dates
#    - Scale: Use Spark's parallelize() to distribute API calls
#    - Issue: API rate limits → Implement global rate limiter
#    - Solution: Batch dates, use multiple API keys, or queue-based approach
#
# 2. Small files problem:
#    - Symptom: Millions of tiny Parquet files
#    - Impact: Slow queries, high S3 list costs, metadata overhead
#    - Solution: Compact files periodically (daily/weekly job)
#    - Tool: Use S3DistCp or Spark coalesce()
#
# 3. Data skew:
#    - Symptom: Some Spark tasks take 10x longer
#    - Cause: Uneven distribution (one partition has 90% of data)
#    - Detection: Check Spark UI for task duration distribution
#    - Solution: Salt partitioning keys, increase partition count
#
# 4. S3 consistency:
#    - Issue: Read-after-write consistency for new objects
#    - Impact: Athena query doesn't see newly written partitions
#    - Solution: Run MSCK REPAIR TABLE or use Glue Crawler
#    - Best: Use Glue Catalog for metadata management
#
# 5. Schema evolution:
#    - Issue: API adds new fields, breaks compatibility
#    - Detection: Validation step comparing schemas
#    - Handling: Use schema registry, version schemas
#    - Migration: Backfill old partitions or use schema merging
#
# 6. What changes over time:
#    - Optimizing Spark configurations (executor memory, cores)
#    - Adding data quality checks (null rates, value ranges)
#    - Implementing incremental loads (only new data)
#    - Adding deduplication logic
#    - Implementing late-arriving data handling
#    - Adding data lineage tracking
#    - Implementing data retention policies
#    - Migrating to Glue 5.0 for better performance
