# SmartSensor Data Pipeline

Data pipeline that extracts weather data from REST APIs, applies transformations, and stores in S3 data lake using AWS Glue and Step Functions.

## Project Overview

This pipeline demonstrates real-world big data engineering patterns:
- **Two-job pattern** for robust API ingestion (check → extract)
- **Sensor grid simulation** generating thousands of data points
- **ETL transformations** with business logic and data quality scoring
- **Multi-environment deployment** (dev/prod) with Terraform
- **Enterprise patterns**: checkpointing, monitoring, error handling

### Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌──────────┐     ┌──────────────┐     ┌───────────┐
│ EventBridge │────>│  Step Functions  │────>│  Check   │────>│   Extract    │────>│  S3 Data  │
│  (Schedule) │     │  (Orchestration) │     │  Glue Job│     │   Glue Job   │     │   Lake    │
└─────────────┘     └──────────────────┘     └──────────┘     └──────────────┘     └───────────┘
                                                                      │
                                                                      ▼
                                                             ┌─────────────────┐
                                                             │ Transformations │
                                                             │  - Temp Convert │
                                                             │  - Categories   │
                                                             │  - Quality Score│
                                                             │  - Aggregates   │
                                                             └─────────────────┘
```

## Data Volume

- **Sensor Grid**: 100 virtual sensors across geographic area
- **Time Range**: 365 days of historical data
- **Expected Rows**: 36,500+ (100 sensors × 365 days)
- **With Transformations**: 15+ columns including derived metrics
- **Output Format**: Partitioned Parquet with Snappy compression

## Infrastructure

### Terraform Modules
- **s3**: Data lake with lifecycle policies (90-day S3 → 365-day Glacier)
- **iam**: Least-privilege roles for Glue and Step Functions
- **glue**: ETL job definitions (check + extract jobs)
- **stepfunctions**: Workflow orchestration with retries
- **eventbridge**: Daily scheduling (3 AM UTC in prod)

### Environments

| Feature | Dev | Production |
|---------|-----|------------|
| Glue Workers | 2 | 5 |
| Schedule | Disabled | Daily 3 AM UTC |
| Log Retention | 7 days | 90 days |
| Data Retention | 90 days | 365 days |
| Checkpoints | S3 only | DynamoDB + S3 |
| Access Logging | Disabled | Enabled |
| Resources | 33 | 37 |

## Quick Start

### Prerequisites
- AWS Account with IAM credentials
- Terraform 1.6+
- Python 3.9+
- Poetry (dependency management)

### Local Development

```bash
# Clone repository
git clone https://github.com/Aysticky/smartsensor-data-raw2qua-S3-pipeline.git
cd smartsensor-data-raw2qua-S3-pipeline

# Install dependencies
poetry install

# Run tests
poetry run pytest tests/

# Format code
poetry run black src/ tests/
poetry run isort src/ tests/
```

### Deploy to AWS

#### Development Environment
```bash
cd terraform/environments/dev

# Initialize Terraform
terraform init

# Review plan
terraform plan

# Deploy
terraform apply

# Trigger manual execution
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:eu-central-1:ACCOUNT_ID:stateMachine:smartsensors-dev-pipeline \
  --name "manual-test-$(date +%s)"
```

#### Production Environment
```bash
cd terraform/environments/prod

terraform init
terraform plan
terraform apply

# Production runs automatically daily at 3 AM UTC
# Monitor via AWS Console or CLI
```

## Two-Job Pattern Explained

### Why Two Jobs?

**Problem**: API endpoints can be flaky, rate-limited, or temporarily down. We don't want to start a heavy extract job if the API is unavailable.

**Solution**: Split into two lightweight jobs:

1. **Check Job** (`check_job.py`)
   - **Purpose**: Validate API connectivity and authentication
   - **Runtime**: ~30 seconds
   - **Resources**: 1 DPU (minimal cost)
   - **Logic**: Make single test API call, verify response
   - **Outcome**: Returns SUCCESS or FAILURE

2. **Extract Job** (`extract_job.py`)
   - **Purpose**: Fetch data for thousands of sensor-date combinations
   - **Runtime**: ~3-5 minutes (for 36,500 rows)
   - **Resources**: 2-5 workers (distributed processing)
   - **Logic**: 
     * Generate sensor grid (100 locations)
     * Fetch data for each sensor × each date
     * Apply transformations (temp conversions, categories, quality scores)
     * Write partitioned Parquet to S3
   - **Triggered**: Only if check job succeeds

### Step Functions Workflow

```json
{
  "CheckAPI": "Validate API is up",
  "If Success → ExtractData": "Process thousands of rows",
  "If Failure → CheckFailed": "Stop pipeline, send alert (future)"
}
```

**Benefits**:
- Fail fast (don't waste 5 mins if API is down)
- Clear separation of concerns
- Independent retry strategies
- Better cost optimization

**File Location**: See [src/glue_jobs/check_job.py](src/glue_jobs/check_job.py) and [src/glue_jobs/extract_job.py](src/glue_jobs/extract_job.py)

## ETL Transformations

The pipeline doesn't just extract - it performs comprehensive transformations:

### Raw Data (API Response)
```json
{
  "dt": "2024-01-15",
  "sensor_id": "SENSOR_0042",
  "latitude": 52.5245,
  "longitude": 13.4135,
  "temperature_max": 8.5,
  "temperature_min": 2.3,
  "precipitation": 1.2
}
```

### Transformed Data (Final Output)
```json
{
  "dt": "2024-01-15",
  "sensor_id": "SENSOR_0042",
  "region": "ZONE_4_2",
  "latitude": 52.5245,
  "longitude": 13.4135,
  
  // Original fields
  "temperature_max": 8.5,
  "temperature_min": 2.3,
  "precipitation": 1.2,
  
  // Calculated fields
  "temperature_max_f": 47.3,
  "temperature_min_f": 36.1,
  "temperature_avg": 5.4,
  "temperature_range": 6.2,
  
  // Business categorizations
  "temp_category": "cold",
  "precipitation_level": "light",
  
  // Data quality
  "is_complete": true,
  "data_quality_score": 100,
  
  // Regional aggregates (window functions)
  "region_avg_temp": 5.8,
  "region_total_precipitation": 125.4,
  
  // Metadata
  "processed_at": "2024-01-15T10:30:45Z",
  "processing_version": "1.0"
}
```

### Transformations Applied
1. **Unit Conversions**: Celsius → Fahrenheit
2. **Calculated Metrics**: Temperature average, range
3. **Categorizations**: Temperature bands (freezing/cold/mild/warm/hot)
4. **Precipitation Levels**: None/light/moderate/heavy/extreme
5. **Data Quality Scoring**: 0-100 based on completeness
6. **Deduplication**: Keep latest record per sensor-date
7. **Regional Aggregates**: Spark window functions for area statistics

**File Location**: See [src/glue_jobs/transformations.py](src/glue_jobs/transformations.py)

## Monitoring & Operations

### View Pipeline Execution
```bash
# List recent executions
aws stepfunctions list-executions \
  --state-machine-arn arn:aws:states:eu-central-1:ACCOUNT_ID:stateMachine:smartsensors-prod-pipeline

# Check specific execution
aws stepfunctions describe-execution \
  --execution-arn <execution-arn>

# View logs
aws logs tail /aws/stepfunctions/smartsensors-prod-pipeline --follow
```

### Query Data in S3
```bash
# List partitions
aws s3 ls s3://smartsensors-prod-raw-data-ACCOUNT_ID/raw/openmeteo/ --recursive

# Download sample data
aws s3 cp s3://smartsensors-prod-raw-data-ACCOUNT_ID/raw/openmeteo/dt=2024-01-15/ . --recursive

# Count total objects
aws s3 ls s3://smartsensors-prod-raw-data-ACCOUNT_ID/raw/ --recursive | wc -l
```

### Data Quality Checks
The pipeline logs data quality metrics:
```
Total Rows: 36,500
Complete Rows: 36,450
Completeness Rate: 99.9%
Null Temperature Count: 25
Null Precipitation Count: 25
```

## Troubleshooting

### Issue: "No data fetched successfully"
**Cause**: API endpoint issue or rate limiting
**Solution**: Check logs, verify API endpoint in variables.tf

### Issue: OutOfMemory in Glue
**Cause**: Too many rows for current worker config
**Solution**: Increase `number_of_workers` in `terraform/environments/{env}/terraform.tfvars`

### Issue: S3 403 Access Denied
**Cause**: IAM permissions issue
**Solution**: Check Glue execution role has S3 write permissions

### Issue: JSONPath errors in Step Functions
**Cause**: Mismatched field names between jobs
**Solution**: Verify Step Functions definition matches Glue output schema


**For this pipeline**: We use timestamp-based CDC via checkpoints. Each run stores:
```json
{
  "last_processed_date": "2024-01-15",
  "next_start_date": "2024-01-16"
}
```

Next run starts from `next_start_date` instead of reprocessing everything.

## Project Structure

```
smartsensor-data-raw2qua-S3-pipeline/
├── src/
│   └── glue_jobs/
│       ├── check_job.py           # API validation job
│       ├── extract_job.py         # Main ETL job (THOUSANDS OF ROWS)
│       └── transformations.py     # Business logic transformations
│
├── terraform/
│   ├── modules/                   # Reusable infrastructure components
│   │   ├── s3/                    # Data lake + lifecycle
│   │   ├── iam/                   # Security roles
│   │   ├── glue/                  # ETL job definitions
│   │   ├── stepfunctions/         # Workflow orchestration
│   │   └── eventbridge/           # Scheduling
│   │
│   └── environments/
│       ├── dev/                   # Development environment
│       └── prod/                  # Production environment
│
├── .github/
│   └── workflows/
│       ├── ci.yml                 # Tests + linting
│       ├── deploy-dev.yml         # Auto-deploy to dev
│       └── deploy-prod.yml        # Manual prod deployment
│
├── tests/                         # Unit tests
├── pyproject.toml                 # Poetry dependencies
└── README.md                      # This file
```


