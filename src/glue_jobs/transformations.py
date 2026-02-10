"""
Data Transformations Module

PURPOSE:
- Apply business logic to raw API data
- Calculate derived metrics
- Categorize data for analytics
- Add data quality indicators

TRANSFORMATIONS:
1. Temperature unit conversions
2. Categorical classifications
3. Calculated aggregates
4. Data quality scoring
5. Deduplication
"""

import logging
from pyspark.sql import DataFrame, functions as F
from pyspark.sql.window import Window

logger = logging.getLogger(__name__)


def apply_transformations(df: DataFrame) -> DataFrame:
    """
    Apply comprehensive transformations to weather data
    
    TRANSFORMATIONS IMPLEMENTED:
    1. Temperature conversion (Celsius to Fahrenheit)
    2. Temperature category classification
    3. Precipitation level categorization
    4. Data quality flags
    5. Calculated fields (temperature range, avg)
    6. Deduplication
    7. Processing metadata
    
    WHY THIS MATTERS:
    - Raw API data is not analytics-ready
    - Business users need derived metrics
    - Data quality validation is critical
    - Standardization across data sources
    
    EXAMPLES:
    - Raw: temperature_max=25.5C
    - Transformed: temperature_max=25.5, temperature_max_f=77.9, temp_category='warm'
    """
    logger.info(f"Starting transformations on {df.count()} rows...")
    
    # 1. Temperature conversions (Celsius to Fahrenheit)
    df = df.withColumn('temperature_max_f', (F.col('temperature_max') * 9/5) + 32)
    df = df.withColumn('temperature_min_f', (F.col('temperature_min') * 9/5) + 32)
    
    # 2. Calculated aggregate fields
    df = df.withColumn('temperature_range', 
                       F.col('temperature_max') - F.col('temperature_min'))
    df = df.withColumn('temperature_avg', 
                       (F.col('temperature_max') + F.col('temperature_min')) / 2)
    
    # 3. Temperature categorization (business logic)
    df = df.withColumn('temp_category', 
        F.when(F.col('temperature_avg') < 0, 'freezing')
         .when(F.col('temperature_avg') < 10, 'cold')
         .when(F.col('temperature_avg') < 20, 'mild')
         .when(F.col('temperature_avg') < 30, 'warm')
         .otherwise('hot')
    )
    
    # 4. Precipitation level classification
    df = df.withColumn('precipitation_level',
        F.when(F.col('precipitation').isNull(), 'unknown')
         .when(F.col('precipitation') == 0, 'none')
         .when(F.col('precipitation') < 2.5, 'light')
         .when(F.col('precipitation') < 10, 'moderate')
         .when(F.col('precipitation') < 50, 'heavy')
         .otherwise('extreme')
    )
    
    # 5. Data quality flags
    df = df.withColumn('is_complete',
        F.when(
            F.col('temperature_max').isNotNull() &
            F.col('temperature_min').isNotNull() &
            F.col('precipitation').isNotNull(),
            True
        ).otherwise(False)
    )
    
    # 6. Data quality score (0-100)
    df = df.withColumn('data_quality_score',
        F.when(F.col('is_complete'), 100)
         .when(F.col('temperature_avg').isNotNull(), 75)
         .otherwise(25)
    )
    
    # 7. Add processing metadata
    df = df.withColumn('processed_at', F.current_timestamp())
    df = df.withColumn('processing_version', F.lit('1.0'))
    
    # 8. Deduplication strategy
    # Keep latest record per sensor per day (based on ingestion_timestamp)
    window_spec = Window.partitionBy('dt', 'sensor_id').orderBy(F.desc('ingestion_timestamp'))
    df = df.withColumn('row_num', F.row_number().over(window_spec))
    df = df.filter(F.col('row_num') == 1).drop('row_num')
    
    # 9. Add regional aggregates (window functions)
    region_window = Window.partitionBy('region', 'dt')
    df = df.withColumn('region_avg_temp', 
                       F.avg('temperature_avg').over(region_window))
    df = df.withColumn('region_total_precipitation', 
                       F.sum('precipitation').over(region_window))
    
    final_count = df.count()
    logger.info(f"Transformations complete. Final row count: {final_count}")
    
    return df


def validate_data_quality(df: DataFrame) -> dict:
    """
    Calculate data quality metrics
    
    Returns dict with:
    - total_rows
    - complete_rows
    - completeness_rate
    - null_temperature_count
    - null_precipitation_count
    """
    total_rows = df.count()
    
    complete_rows = df.filter(F.col('is_complete') == True).count()
    null_temp = df.filter(F.col('temperature_avg').isNull()).count()
    null_precip = df.filter(F.col('precipitation').isNull()).count()
    
    metrics = {
        'total_rows': total_rows,
        'complete_rows': complete_rows,
        'completeness_rate': (complete_rows / total_rows * 100) if total_rows > 0 else 0,
        'null_temperature_count': null_temp,
        'null_precipitation_count': null_precip,
    }
    
    logger.info(f"Data Quality Metrics: {metrics}")
    
    return metrics
