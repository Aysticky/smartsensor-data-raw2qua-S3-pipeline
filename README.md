# SmartSensor Data Pipeline: Raw to Qualified (S3)

Enterprise-grade data pipeline using AWS Glue Spark for REST API ingestion into S3 data lake.

## Architecture

This pipeline implements the **two-job pattern** (check → extract) for robust REST API ingestion:

1. **Check Job**: Validates API availability and authentication
2. **Extract Job**: Performs incremental data extraction with pagination
3. **Step Functions**: Orchestrates the workflow with error handling

## Infrastructure

- **Infrastructure as Code**: Terraform
- **Environment Strategy**: Dev and Prod (no staging to optimize costs)
- **Build Tool**: Poetry
- **Orchestration**: AWS Step Functions
- **Compute**: AWS Glue Spark (distributed processing)
- **Storage**: S3 (partitioned Parquet)
- **Scheduling**: EventBridge

## Project Structure

```
.
├── terraform/              # Infrastructure as Code
│   ├── environments/       # Environment-specific configs
│   │   ├── dev/
│   │   └── prod/
│   ├── modules/           # Reusable Terraform modules
│   │   ├── s3/
│   │   ├── glue/
│   │   ├── iam/
│   │   ├── stepfunctions/
│   │   └── eventbridge/
│   └── backend.tf
├── src/                   # Source code
│   ├── glue_jobs/        # Glue job scripts
│   │   ├── check_job.py
│   │   └── extract_job.py
│   └── common/           # Shared utilities
│       ├── api_client.py
│       ├── auth.py
│       └── utils.py
├── .github/
│   └── workflows/        # CI/CD pipelines
├── tests/
├── pyproject.toml        # Poetry configuration
└── README.md
```

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0
- Python >= 3.9
- Poetry

## Setup

```bash
# Install dependencies
poetry install

# Initialize Terraform
cd terraform/environments/dev
terraform init

# Plan infrastructure
terraform plan

# Apply infrastructure
terraform apply
```

## Enterprise Patterns Implemented

### Pattern 1: OAuth2 + Pagination + Incremental Cursor
- Token refresh with expiry handling
- Cursor-based pagination
- Rate limit backoff (exponential)
- Idempotent writes
- Checkpoint management

### Pattern 2: Async Export + Polling + Download
- Export request initiation
- Status polling with timeout
- File download and processing
- Cleanup and state management

## Monitoring & Operations

Key areas requiring ongoing attention:

1. **API Rate Limits**: Monitor CloudWatch for 429 errors
2. **Glue Job Duration**: Track execution times for cost optimization
3. **S3 Partition Pruning**: Ensure proper partition strategy
4. **Checkpoint State**: Validate incremental extraction cursors
5. **Data Quality**: Implement row count validation

## Development Workflow

1. Make changes in feature branch
2. Commit to GitHub
3. CI/CD runs validation and tests
4. Deploy to dev automatically
5. Manual approval for prod deployment

## License

Proprietary