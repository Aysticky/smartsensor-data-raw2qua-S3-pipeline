"""
Common utilities for Glue jobs

DESIGN PHILOSOPHY:
- Reusable components across check and extract jobs
- Centralized error handling and logging
- Type hints for better IDE support and documentation
"""

import json
import logging
from datetime import date, datetime, timedelta
from typing import Any, Dict, Optional

import boto3
from botocore.exceptions import ClientError

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class CheckpointManager:
    """
    Manage checkpoints for incremental extraction

    CHECKPOINT STRATEGY:
    - Store last successful extraction cursor/timestamp
    - Use S3 for simplicity (can switch to DynamoDB for atomicity)
    - Include metadata: last_run_time, records_processed, status

    OPERATIONAL CONSIDERATIONS:
    - Checkpoints can become corrupted (network errors during write)
    - Always validate checkpoint data before using
    - Keep backup of last N checkpoints
    - Alert if checkpoint is stale (>24 hours)
    """

    def __init__(self, s3_bucket: str, checkpoint_prefix: str):
        self.s3_client = boto3.client('s3')
        self.s3_bucket = s3_bucket
        self.checkpoint_prefix = checkpoint_prefix

    def read_checkpoint(self, checkpoint_key: str) -> Optional[Dict[str, Any]]:
        """Read checkpoint from S3"""
        full_key = f"{self.checkpoint_prefix}{checkpoint_key}.json"

        try:
            response = self.s3_client.get_object(
                Bucket=self.s3_bucket,
                Key=full_key
            )
            checkpoint_data = json.loads(response['Body'].read().decode('utf-8'))
            logger.info(f"Loaded checkpoint from s3://{self.s3_bucket}/{full_key}")
            return checkpoint_data

        except self.s3_client.exceptions.NoSuchKey:
            logger.warning(f"No checkpoint found at s3://{self.s3_bucket}/{full_key}")
            return None

        except ClientError as e:
            logger.error(f"Error reading checkpoint: {e}")
            return None

    def write_checkpoint(self, checkpoint_key: str, data: Dict[str, Any]) -> bool:
        """
        Write checkpoint to S3

        ATOMICITY NOTE:
        - S3 PutObject is atomic, but not transactional
        - For critical checkpoints, consider:
          1. Write to temp location first
          2. Validate the write
          3. Copy/rename to final location
        """
        full_key = f"{self.checkpoint_prefix}{checkpoint_key}.json"

        # Add metadata
        data['_checkpoint_updated_at'] = datetime.utcnow().isoformat()

        try:
            self.s3_client.put_object(
                Bucket=self.s3_bucket,
                Key=full_key,
                Body=json.dumps(data, indent=2),
                ContentType='application/json'
            )
            logger.info(f"Wrote checkpoint to s3://{self.s3_bucket}/{full_key}")
            return True

        except ClientError as e:
            logger.error(f"Error writing checkpoint: {e}")
            return False


class SecretsManager:
    """
    Retrieve secrets from AWS Secrets Manager

    SECURITY BEST PRACTICES:
    - Never log secret values
    - Cache secrets to reduce API calls (but watch for rotation)
    - Use IAM conditions to restrict which jobs can access which secrets
    - Enable CloudTrail to audit secret access

    ROTATION HANDLING:
    - If secret is rotated during job execution, retry logic should refetch
    - Set max_age for cached secrets
    """

    def __init__(self, region: str = 'eu-central-1'):
        self.client = boto3.client('secretsmanager', region_name=region)
        self._cache: Dict[str, Dict[str, Any]] = {}

    def get_secret(self, secret_name: str, max_age_seconds: int = 300) -> Dict[str, Any]:
        """
        Get secret from Secrets Manager with caching

        COST OPTIMIZATION:
        - Secrets Manager charges $0.05 per 10,000 API calls
        - Cache secrets during job execution
        - For long-running jobs, implement cache expiry
        """
        now = datetime.utcnow()

        # Check cache
        if secret_name in self._cache:
            cached_data = self._cache[secret_name]
            cache_age = (now - cached_data['fetched_at']).seconds

            if cache_age < max_age_seconds:
                logger.debug(f"Using cached secret: {secret_name}")
                return cached_data['value']

        # Fetch from Secrets Manager
        try:
            response = self.client.get_secret_value(SecretId=secret_name)
            secret_value = json.loads(response['SecretString'])

            # Cache it
            self._cache[secret_name] = {
                'value': secret_value,
                'fetched_at': now
            }

            logger.info(f"Fetched secret: {secret_name}")
            return secret_value

        except ClientError as e:
            error_code = e.response['Error']['Code']

            if error_code == 'ResourceNotFoundException':
                logger.error(f"Secret not found: {secret_name}")
            elif error_code == 'AccessDeniedException':
                logger.error(f"Access denied to secret: {secret_name}")
            else:
                logger.error(f"Error fetching secret {secret_name}: {e}")

            raise


def daterange(start: date, end: date):
    """
    Generate date range (inclusive)

    USAGE NOTE:
    - For large date ranges, consider batching
    - Memory-efficient generator pattern
    """
    current = start
    while current <= end:
        yield current
        current += timedelta(days=1)


def parse_date(date_string: str) -> date:
    """
    Parse date string with support for relative dates

    INCREMENTAL EXTRACTION PATTERN:
    - Support 'yesterday', 'today', 'last_week'
    - Useful for scheduled jobs that always process recent data
    """
    date_string = date_string.lower().strip()
    today = date.today()

    if date_string == 'yesterday':
        return today - timedelta(days=1)
    elif date_string == 'today':
        return today
    elif date_string == 'last_week':
        return today - timedelta(days=7)
    else:
        # Assume ISO format: YYYY-MM-DD
        return date.fromisoformat(date_string)


def validate_config(config: Dict[str, Any], required_keys: list) -> None:
    """
    Validate job configuration

    FAIL-FAST PRINCIPLE:
    - Check all prerequisites before starting expensive operations
    - Better to fail in 1 second than after 10 minutes of processing
    """
    missing_keys = [key for key in required_keys if key not in config]

    if missing_keys:
        raise ValueError(f"Missing required configuration keys: {missing_keys}")

    logger.info("Configuration validation passed")
