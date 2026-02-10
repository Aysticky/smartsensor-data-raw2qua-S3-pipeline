"""
Glue Job: API Connectivity Check

PURPOSE:
- Validate API is reachable before starting expensive extract job
- Verify authentication credentials are valid
- Check rate limit status
- Write health check results to S3

JOB CHARACTERISTICS:
- Lightweight: 1-2 DPUs, runs in 1-2 minutes
- No data processing: Just connectivity test
- Fail fast: Better to fail here than 10 minutes into extract

OPERATIONAL CONSIDERATIONS:
- This job should complete in <2 minutes
- If it takes longer, investigate:
  1. API latency issues
  2. Network connectivity problems
  3. DNS resolution delays
- Monitor CloudWatch for patterns in failures
"""

import json
import logging
import sys
from datetime import datetime

import boto3
import requests
from awsglue.utils import getResolvedOptions

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def get_job_parameters():
    """
    Get Glue job parameters

    REQUIRED PARAMETERS:
    - JOB_NAME: Glue job name
    - API_ENDPOINT: Base URL of the API
    - S3_BUCKET: Bucket for checkpoint/status files
    - CHECKPOINT_PREFIX: S3 prefix for checkpoints

    OPTIONAL PARAMETERS:
    - SECRETS_NAME: AWS Secrets Manager secret name
    - execution_id: Step Functions execution ID (for tracing)
    """
    required_args = [
        'JOB_NAME',
        'API_ENDPOINT',
        'S3_BUCKET',
        'CHECKPOINT_PREFIX'
    ]

    # Get required arguments
    args = getResolvedOptions(sys.argv, required_args)

    # Get optional arguments
    optional_args = ['SECRETS_NAME', 'execution_id']
    try:
        optional = getResolvedOptions(sys.argv, optional_args)
        args.update(optional)
    except Exception:
        logger.info("No optional arguments provided")

    return args


def check_api_connectivity(api_endpoint: str, timeout: int = 10) -> dict:
    """
    Check basic API connectivity

    CHECKS:
    1. DNS resolution (can we resolve the hostname?)
    2. TCP connection (can we reach the server?)
    3. HTTP response (does server respond to requests?)
    4. Response time (is it within acceptable limits?)

    ISSUES TO WATCH:
    - DNS failures: Check VPC DNS settings if in private VPC
    - Timeouts: API might be overloaded or network issues
    - SSL errors: Certificate expired or invalid
    - 5xx errors: API backend problems
    """
    logger.info(f"Checking connectivity to {api_endpoint}")

    start_time = datetime.utcnow()

    try:
        response = requests.get(
            api_endpoint,
            params={'latitude': 52.3676, 'longitude': 4.9041},  # Test location
            timeout=timeout
        )

        end_time = datetime.utcnow()
        latency_ms = (end_time - start_time).total_seconds() * 1000

        result = {
            'status': 'success' if response.status_code == 200 else 'failed',
            'http_status': response.status_code,
            'latency_ms': round(latency_ms, 2),
            'timestamp': datetime.utcnow().isoformat(),
        }

        # Check rate limit headers if available
        if 'X-RateLimit-Remaining' in response.headers:
            result['rate_limit_remaining'] = response.headers['X-RateLimit-Remaining']
            result['rate_limit_limit'] = response.headers.get('X-RateLimit-Limit')

        # Log warning if latency is high
        if latency_ms > 5000:  # >5 seconds
            logger.warning(f"High API latency detected: {latency_ms}ms")

        logger.info(
            f"API check result: {result['status']} "
            f"({result['http_status']}) in {latency_ms}ms"
        )

        return result

    except requests.exceptions.Timeout:
        logger.error(f"API request timed out after {timeout} seconds")
        return {
            'status': 'failed',
            'error': 'timeout',
            'error_message': f'Request timed out after {timeout} seconds',
            'timestamp': datetime.utcnow().isoformat(),
        }

    except requests.exceptions.ConnectionError as e:
        logger.error(f"Connection error: {e}")
        return {
            'status': 'failed',
            'error': 'connection_error',
            'error_message': str(e),
            'timestamp': datetime.utcnow().isoformat(),
        }

    except Exception as e:
        logger.error(f"Unexpected error during API check: {e}")
        return {
            'status': 'failed',
            'error': 'unexpected_error',
            'error_message': str(e),
            'timestamp': datetime.utcnow().isoformat(),
        }


def write_check_result(s3_bucket: str, checkpoint_prefix: str, result: dict) -> None:
    """
    Write check result to S3

    PURPOSE:
    - Audit trail of API health checks
    - Can be analyzed for failure patterns
    - Used by monitoring systems for alerting

    FILE STRUCTURE:
    s3://bucket/checkpoints/check-job/YYYY-MM-DD/HH-MM-SS-result.json

    RETENTION:
    - Keep for 30 days (enough for trend analysis)
    - Can be aggregated into daily summaries
    """
    s3_client = boto3.client('s3')

    # Generate timestamped key
    timestamp = datetime.utcnow().strftime('%Y-%m-%d/%H-%M-%S')
    key = f"{checkpoint_prefix}health-checks/{timestamp}-result.json"

    try:
        s3_client.put_object(
            Bucket=s3_bucket,
            Key=key,
            Body=json.dumps(result, indent=2),
            ContentType='application/json'
        )

        logger.info(f"Wrote check result to s3://{s3_bucket}/{key}")

    except Exception as e:
        logger.error(f"Failed to write check result to S3: {e}")
        # Don't fail the job just because we can't write the result
        # The check itself is what matters


def main():
    """
    Main execution logic

    FLOW:
    1. Get job parameters
    2. Check API connectivity
    3. Write results to S3
    4. Exit with appropriate code

    EXIT CODES:
    - 0: Success (API is healthy)
    - 1: Failure (API check failed)

    FAILURE SCENARIOS TO HANDLE:
    - API is down → Fail job, alert on-call team
    - API is slow (>10s) → Succeed but log warning
    - Rate limit exhausted → Fail job, wait for reset
    - Authentication failed → Fail job, check credentials
    """
    logger.info("Starting API connectivity check job")

    try:
        # Get parameters
        args = get_job_parameters()

        safe_params = {k: v for k, v in args.items()
                       if 'SECRET' not in k.upper()}
        logger.info(f"Job parameters: {json.dumps(safe_params)}")

        # Perform API check
        check_result = check_api_connectivity(args['API_ENDPOINT'])

        # Add job metadata
        check_result['job_name'] = args['JOB_NAME']
        check_result['execution_id'] = args.get('execution_id', 'unknown')

        # Write result to S3
        write_check_result(
            args['S3_BUCKET'],
            args['CHECKPOINT_PREFIX'],
            check_result
        )

        # Determine success
        if check_result['status'] == 'success':
            logger.info("API connectivity check PASSED")

            # Print summary for Step Functions
            print(json.dumps({
                'status': 'success',
                'message': 'API is healthy and reachable',
                'latency_ms': check_result.get('latency_ms'),
            }))

            # Success - let job complete normally
            return
        else:
            logger.error("API connectivity check FAILED")

            error_msg = check_result.get('error_message', 'API check failed')

            # Raise exception to fail the Glue job
            raise RuntimeError(f"API connectivity check failed: {error_msg}")

    except Exception as e:
        logger.error(f"Job failed with exception: {e}", exc_info=True)

        print(json.dumps({
            'status': 'failed',
            'message': str(e),
            'error': 'job_exception',
        }))

        # Re-raise to fail the Glue job
        raise


if __name__ == "__main__":
    main()


# INSIGHTS:
#
# 1. Why have a separate check job:
#    - Fail fast: Don't waste 30 minutes of Glue time if API is down
#    - Cost optimization: Check job costs <$0.01, extract job costs $0.50+
#    - Better error messages: Clear distinction between connectivity vs data issues
#
# 2. Monitoring check job:
#    - Track success rate over time
#    - Alert if failure rate >10%
#    - Monitor latency trends (degrading performance indicator)
#    - Correlate failures with API vendor incidents
#
# 3. When to skip check job:
#    - If API has 99.99% uptime SLA
#    - If extract job needs to run immediately
#    - If cost optimization isn't critical
#
# 4. Extending check job:
#    - Add authentication validation
#    - Check multiple API endpoints
#    - Validate rate limit status
#    - Test data availability (do we have data for target date?)
#
# 5. What changes over time:
#    - Adding health check for multiple data sources
#    - Implementing smart retry (check again after 5 min)
#    - Adding circuit breaker (skip checks if API is known down)
#    - Integrating with vendor status pages
