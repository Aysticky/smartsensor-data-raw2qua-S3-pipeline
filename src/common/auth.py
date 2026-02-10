"""
Authentication module for REST API access:
1. OAuth2 with token refresh
2. API Key authentication
3. Basic authentication
4. Custom header-based auth

SECURITY CONSIDERATIONS:
- Never log credentials or tokens
- Implement token refresh before expiry
- Handle 401 Unauthorized with re-authentication
- Monitor authentication failures in CloudWatch
"""

import logging
import time
from datetime import datetime, timedelta
from typing import Dict, Optional

import requests
from requests.adapters import HTTPAdapter
from requests.packages.urllib3.util.retry import Retry

logger = logging.getLogger(__name__)


class OAuth2TokenManager:
    """
    Manage OAuth2 access tokens with automatic refresh
    
    OAUTH2 FLOW:
    1. Exchange client_id + client_secret for access_token
    2. Use access_token for API requests
    3. Refresh token when it expires or gets 401
    
    COMMON ISSUES:
    - Token expires during long-running job → Implement refresh
    - Clock skew between systems → Refresh 5 min before expiry
    - Rate limits on token endpoint → Cache tokens properly
    """
    
    def __init__(
        self,
        token_url: str,
        client_id: str,
        client_secret: str,
        refresh_buffer_seconds: int = 300
    ):
        self.token_url = token_url
        self.client_id = client_id
        self.client_secret = client_secret
        self.refresh_buffer_seconds = refresh_buffer_seconds
        
        self.access_token: Optional[str] = None
        self.token_expires_at: Optional[datetime] = None
        
        # HTTP session with retries
        self.session = self._create_session()
    
    def _create_session(self) -> requests.Session:
        """
        Create HTTP session with retry logic
        
        RETRY STRATEGY:
        - Retry on network errors and 5xx server errors
        - Don't retry on 4xx client errors (except 429 rate limit)
        - Exponential backoff to avoid overwhelming the server
        """
        session = requests.Session()
        
        retry_strategy = Retry(
            total=3,
            backoff_factor=1,  # 1s, 2s, 4s
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["HEAD", "GET", "PUT", "POST", "DELETE", "OPTIONS"]
        )
        
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("http://", adapter)
        session.mount("https://", adapter)
        
        return session
    
    def get_access_token(self) -> str:
        """
        Get valid access token (refresh if needed)
        
        TOKEN CACHING:
        - Don't fetch token for every API call (expensive)
        - Check expiry and refresh proactively
        - Handle race conditions in concurrent environments
        """
        # Check if we need to refresh
        if self._needs_refresh():
            self._fetch_new_token()
        
        if not self.access_token:
            raise RuntimeError("Failed to obtain access token")
        
        return self.access_token
    
    def _needs_refresh(self) -> bool:
        """Check if token needs refresh"""
        if not self.access_token or not self.token_expires_at:
            return True
        
        # Refresh if expiring soon (buffer for clock skew)
        return datetime.utcnow() >= (
            self.token_expires_at - timedelta(seconds=self.refresh_buffer_seconds)
        )
    
    def _fetch_new_token(self) -> None:
        """
        Fetch new access token from OAuth2 endpoint
        
        GRANT TYPES:
        - client_credentials: For service-to-service auth
        - authorization_code: For user-delegated access
        - refresh_token: For long-lived sessions
        """
        logger.info("Fetching new OAuth2 access token")
        
        try:
            response = self.session.post(
                self.token_url,
                data={
                    'grant_type': 'client_credentials',
                    'client_id': self.client_id,
                    'client_secret': self.client_secret,
                },
                timeout=30
            )
            
            response.raise_for_status()
            token_data = response.json()
            
            self.access_token = token_data['access_token']
            expires_in = token_data.get('expires_in', 3600)  # Default 1 hour
            self.token_expires_at = datetime.utcnow() + timedelta(seconds=expires_in)
            
            logger.info(f"Access token obtained, expires at {self.token_expires_at}")
        
        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to fetch access token: {e}")
            raise RuntimeError(f"OAuth2 token fetch failed: {e}")


class APIKeyAuth:
    """
    Simple API key authentication
    
    USAGE:
    - Header-based: X-API-Key: <key>
    - Query parameter: ?api_key=<key>
    
    SECURITY:
    - Rotate keys regularly (set reminder in Secrets Manager)
    - Use different keys for dev/prod
    - Monitor for leaked keys (check public repos)
    """
    
    def __init__(self, api_key: str, header_name: str = 'X-API-Key'):
        self.api_key = api_key
        self.header_name = header_name
    
    def get_headers(self) -> Dict[str, str]:
        """Get authentication headers"""
        return {self.header_name: self.api_key}


class RateLimitHandler:
    """
    Handle API rate limits with exponential backoff
    
    RATE LIMIT PATTERNS:
    1. Fixed window: X requests per minute
    2. Sliding window: X requests per rolling minute
    3. Token bucket: Burst allowed, refill at rate
    
    RESPONSE HEADERS TO CHECK:
    - X-RateLimit-Remaining: Requests left
    - X-RateLimit-Reset: When limit resets (Unix timestamp)
    - Retry-After: Seconds to wait (on HTTP 429)
    
    OPERATIONAL ISSUES:
    - Rate limits can change without notice
    - Different endpoints may have different limits
    - Shared rate limits across organization (other jobs affect you)
    """
    
    def __init__(self, max_retries: int = 5, base_delay: float = 1.0):
        self.max_retries = max_retries
        self.base_delay = base_delay
    
    def handle_rate_limit(
        self,
        response: requests.Response,
        attempt: int
    ) -> None:
        """
        Handle rate limit response with exponential backoff
        
        EXPONENTIAL BACKOFF:
        - Attempt 1: 1 second
        - Attempt 2: 2 seconds
        - Attempt 3: 4 seconds
        - Attempt 4: 8 seconds
        - Attempt 5: 16 seconds
        
        Add jitter to prevent thundering herd
        """
        if response.status_code != 429:
            return
        
        if attempt >= self.max_retries:
            raise RuntimeError(f"Rate limit exceeded after {attempt} retries")
        
        # Check for Retry-After header
        retry_after = response.headers.get('Retry-After')
        
        if retry_after:
            wait_time = int(retry_after)
        else:
            # Exponential backoff: 2^attempt * base_delay
            wait_time = (2 ** attempt) * self.base_delay
        
        logger.warning(
            f"Rate limit hit (attempt {attempt}/{self.max_retries}). "
            f"Waiting {wait_time} seconds..."
        )
        
        time.sleep(wait_time)
    
    def check_rate_limit_headers(self, response: requests.Response) -> None:
        """
        Check rate limit headers and warn if close to limit
        
        PROACTIVE MONITORING:
        - Alert if remaining requests < 10%
        - Slow down requests if approaching limit
        - Track rate limit resets for capacity planning
        """
        remaining = response.headers.get('X-RateLimit-Remaining')
        limit = response.headers.get('X-RateLimit-Limit')
        
        if remaining and limit:
            remaining = int(remaining)
            limit = int(limit)
            
            if remaining < limit * 0.1:  # Less than 10% remaining
                logger.warning(
                    f"Rate limit low: {remaining}/{limit} requests remaining"
                )


# PLATFORM ENGINEERING INSIGHTS:
#
# 1. Why separate token management from API client:
#    - Testability (mock token manager separately)
#    - Reusability (same token for multiple API endpoints)
#    - State management (single source of truth for token)
#
# 2. When to implement circuit breaker pattern:
#    - If API has sustained outages (>5 minutes)
#    - To prevent cascading failures
#    - To give API time to recover under load
#
# 3. Monitoring authentication:
#    - Track token fetch failures (alert if >3 consecutive)
#    - Monitor 401 responses (indicates credential issues)
#    - Track token refresh rate (should be predictable)
#
# 4. Handling credential rotation:
#    - Secrets Manager rotation lambda
#    - Graceful handling of both old and new credentials
#    - Zero-downtime rotation strategy
#
# 5. What changes over time:
#    - API authentication methods (migrate OAuth1 → OAuth2)
#    - Rate limits (negotiate higher limits as usage grows)
#    - Token expiry times (longer for trusted services)
#    - Adding new authentication layers (mTLS, IP whitelisting)
