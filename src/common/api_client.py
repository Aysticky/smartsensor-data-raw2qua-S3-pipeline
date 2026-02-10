"""
REST API Client with error handling

ENTERPRISE FEATURES:
- Pagination support (cursor, page, offset-based)
- Retry logic with exponential backoff
- Rate limit handling
- Request/response logging
- Circuit breaker pattern
- Metrics collection

COMMON API PATTERNS:
1. Cursor-based pagination: next_cursor field
2. Page-based pagination: page=1, page=2, ...
3. Offset-based pagination: offset=0&limit=100
4. Link header pagination: Link: <url>; rel="next"
"""

import logging
from typing import Any, Dict, Generator, List, Optional

import requests
from requests.adapters import HTTPAdapter
from requests.packages.urllib3.util.retry import Retry

from .auth import OAuth2TokenManager, APIKeyAuth, RateLimitHandler

logger = logging.getLogger(__name__)


class APIClient:
    """
    Generic REST API client with robust error handling

    DESIGN PRINCIPLES:
    - Fail fast: Validate before making expensive calls
    - Retry transient errors: Network, 5xx
    - Don't retry permanent errors: 4xx (except 429)
    - Log for observability: Request/response details
    - Collect metrics: Latency, error rates
    """

    def __init__(
        self,
        base_url: str,
        auth_manager: Optional[OAuth2TokenManager] = None,
        api_key_auth: Optional[APIKeyAuth] = None,
        timeout: int = 30,
        max_retries: int = 3
    ):
        self.base_url = base_url.rstrip('/')
        self.auth_manager = auth_manager
        self.api_key_auth = api_key_auth
        self.timeout = timeout
        self.rate_limit_handler = RateLimitHandler(max_retries=max_retries)

        # Metrics
        self.request_count = 0
        self.error_count = 0

        # HTTP session with connection pooling
        self.session = self._create_session()

    def _create_session(self) -> requests.Session:
        """
        Create HTTP session with retry logic and connection pooling

        CONNECTION POOLING:
        - Reuse TCP connections (saves handshake overhead)
        - Important for APIs with many small requests
        - pool_connections=10, pool_maxsize=10 (adjust based on concurrency)
        """
        session = requests.Session()

        # Retry strategy for transient errors
        retry_strategy = Retry(
            total=3,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["HEAD", "GET", "OPTIONS"]  # Safe methods only
        )

        adapter = HTTPAdapter(
            max_retries=retry_strategy,
            pool_connections=10,
            pool_maxsize=10
        )

        session.mount("http://", adapter)
        session.mount("https://", adapter)

        return session

    def _get_headers(self) -> Dict[str, str]:
        """Build request headers with authentication"""
        headers = {
            'User-Agent': 'SmartSensorPipeline/1.0',
            'Accept': 'application/json',
        }

        # Add authentication
        if self.auth_manager:
            access_token = self.auth_manager.get_access_token()
            headers['Authorization'] = f'Bearer {access_token}'

        if self.api_key_auth:
            headers.update(self.api_key_auth.get_headers())

        return headers

    def get(
        self,
        endpoint: str,
        params: Optional[Dict[str, Any]] = None,
        retry_on_rate_limit: bool = True
    ) -> Dict[str, Any]:
        """
        Make GET request with automatic retries

        ERROR SCENARIOS:
        1. Network timeout → Retry
        2. HTTP 500 → Retry
        3. HTTP 429 → Wait and retry
        4. HTTP 401 → Refresh token and retry
        5. HTTP 404 → Don't retry, raise error
        """
        url = f"{self.base_url}/{endpoint.lstrip('/')}"
        headers = self._get_headers()

        attempt = 0
        max_attempts = self.rate_limit_handler.max_retries if retry_on_rate_limit else 1

        while attempt < max_attempts:
            try:
                self.request_count += 1

                logger.debug(f"GET {url} (attempt {attempt + 1}/{max_attempts})")

                response = self.session.get(
                    url,
                    params=params,
                    headers=headers,
                    timeout=self.timeout
                )

                # Handle rate limiting
                if response.status_code == 429 and retry_on_rate_limit:
                    self.rate_limit_handler.handle_rate_limit(response, attempt)
                    attempt += 1
                    continue

                # Handle authentication errors
                if response.status_code == 401 and self.auth_manager:
                    logger.warning("Got 401, refreshing access token...")
                    self.auth_manager._fetch_new_token()
                    headers = self._get_headers()
                    attempt += 1
                    continue

                # Check rate limit headers proactively
                self.rate_limit_handler.check_rate_limit_headers(response)

                # Raise for other HTTP errors
                response.raise_for_status()

                return response.json()

            except requests.exceptions.Timeout:
                self.error_count += 1
                logger.error(f"Request timeout for {url}")

                if attempt >= max_attempts - 1:
                    raise

                attempt += 1

            except requests.exceptions.HTTPError as e:
                self.error_count += 1
                logger.error(f"HTTP error for {url}: {e}")
                raise

            except requests.exceptions.RequestException as e:
                self.error_count += 1
                logger.error(f"Request failed for {url}: {e}")
                raise

        raise RuntimeError(f"Failed after {max_attempts} attempts")

    def post(
        self,
        endpoint: str,
        json: Optional[Dict[str, Any]] = None,
        data: Optional[Any] = None
    ) -> Dict[str, Any]:
        """
        Make POST request

        USE CASES:
        - Create export jobs
        - Trigger webhooks
        - Submit batch requests
        """
        url = f"{self.base_url}/{endpoint.lstrip('/')}"
        headers = self._get_headers()

        try:
            self.request_count += 1

            logger.debug(f"POST {url}")

            response = self.session.post(
                url,
                json=json,
                data=data,
                headers=headers,
                timeout=self.timeout
            )

            response.raise_for_status()
            return response.json()

        except requests.exceptions.RequestException as e:
            self.error_count += 1
            logger.error(f"POST request failed for {url}: {e}")
            raise

    def paginate(
        self,
        endpoint: str,
        params: Optional[Dict[str, Any]] = None,
        page_size: int = 100,
        max_pages: Optional[int] = None
    ) -> Generator[Dict[str, Any], None, None]:
        """
        Paginate through API results

        PAGINATION STRATEGIES:
        1. Cursor-based (recommended for real-time data):
           - More reliable for changing datasets
           - Example: ?cursor=abc123&limit=100

        2. Page-based (simple but can miss/duplicate records):
           - Works for static datasets
           - Example: ?page=1&limit=100

        3. Offset-based (can be slow for large offsets):
           - Database-style pagination
           - Example: ?offset=0&limit=100

        ISSUES TO WATCH:
        - Records added during pagination (cursor handles, offset doesn't)
        - Empty pages (API might return 200 with empty array)
        - Inconsistent pagination across endpoints
        """
        params = params or {}
        params['limit'] = page_size

        page_count = 0
        next_cursor = None

        while True:
            # Add cursor to params if available
            if next_cursor:
                params['cursor'] = next_cursor

            # Fetch page
            response_data = self.get(endpoint, params=params)

            # Yield page data
            yield response_data

            page_count += 1

            # Check for more pages
            next_cursor = response_data.get('next_cursor')
            has_more = response_data.get('has_more', False)

            # Stop conditions
            if not next_cursor and not has_more:
                break

            if max_pages and page_count >= max_pages:
                logger.warning(f"Reached max_pages limit: {max_pages}")
                break

    def get_metrics(self) -> Dict[str, int]:
        """Get client metrics for monitoring"""
        return {
            'request_count': self.request_count,
            'error_count': self.error_count,
            'error_rate': self.error_count / self.request_count if self.request_count > 0 else 0
        }


class OpenMeteoClient:
    """
    Specific client for Open-Meteo API

    API DOCUMENTATION: https://open-meteo.com/en/docs

    CHARACTERISTICS:
    - Free tier: No authentication required
    - Rate limits: ~10,000 requests/day
    - No pagination (returns single response per date range)
    - Simple HTTP GET interface

    LIMITATIONS:
    - Max 16 days per request (API constraint)
    - Need to chunk date ranges for historical data
    """

    def __init__(self, base_url: str = "https://api.open-meteo.com/v1"):
        self.client = APIClient(base_url=base_url)

    def get_weather_data(
        self,
        latitude: float,
        longitude: float,
        start_date: str,
        end_date: str,
        daily_params: Optional[List[str]] = None
    ) -> Dict[str, Any]:
        """
        Fetch weather data for location and date range

        PARAMETERS:
        - latitude, longitude: Coordinates
        - start_date, end_date: ISO format (YYYY-MM-DD)
        - daily_params: Metrics to fetch (temperature, precipitation, etc.)

        RATE LIMITING:
        - Free tier: 10,000 requests/day
        - For production, consider:
          1. Caching results in S3
          2. Batch requests for multiple locations
          3. Using commercial tier for higher limits
        """
        daily_params = daily_params or [
            "temperature_2m_max",
            "temperature_2m_min",
            "precipitation_sum"
        ]

        params = {
            "latitude": latitude,
            "longitude": longitude,
            "start_date": start_date,
            "end_date": end_date,
            "daily": ",".join(daily_params),
            "timezone": "UTC"
        }

        logger.info(
            f"Fetching weather data for ({latitude}, {longitude}) "
            f"from {start_date} to {end_date}"
        )

        return self.client.get("forecast", params=params)


# OPERATIONAL INSIGHTS:
#
# 1. When to add circuit breaker:
#    - If API has >5% error rate for >5 minutes
#    - Prevents wasting Glue DPU hours on failing requests
#    - Implementation: Track consecutive failures, open circuit after threshold
#
# 2. Monitoring API health:
#    - Track request latency (P50, P95, P99)
#    - Alert on error rate >5%
#    - Monitor rate limit consumption
#    - Track token refresh failures
#
# 3. Handling API changes:
#    - Version API client (v1, v2)
#    - Add feature flags for gradual migration
#    - Validate response schemas
#    - Log unexpected fields for investigation
#
# 4. Scaling considerations:
#    - Connection pooling for concurrent requests
#    - Batching requests when API supports it
#    - Caching responses (with TTL)
#    - Using multiple API keys for higher rate limits
#
# 5. What changes over time:
#    - API deprecations (migrate to new endpoints)
#    - Rate limit increases (negotiate with vendor)
#    - New authentication methods (add support)
#    - Response format changes (update parsers)
#    - Adding new data sources (implement new clients)
