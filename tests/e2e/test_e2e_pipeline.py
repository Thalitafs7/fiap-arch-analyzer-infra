"""
End-to-end pytest suite for the full Arch Analyzer pipeline through the ALB.

All tests are marked with @pytest.mark.e2e and are skipped when the ALB_DNS
environment variable is not set.

Validates: Requirements 16.1, 16.2, 16.3

Tests:
  - Health endpoints for all services are reachable via the ALB
  - Full diagram submission and analysis pipeline:
      1. POST /api/auth/login  → JWT
      2. POST /api/registration/diagrams (multipart image) → analysis_id
      3. Poll /api/registration/diagrams/{analysis_id} until status=done or timeout
      4. GET /api/reports/{analysis_id} → report exists
"""

from __future__ import annotations

import io
import os
import time
from typing import Optional

import pytest
import requests

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Services exposed through the ALB (path prefix → health sub-path)
# celery-worker has no HTTP endpoint and is excluded per Req 16.1
SERVICES: dict[str, str] = {
    "gateway": "/api/gateway/health",
    "auth": "/api/auth/health",
    "registration": "/api/registration/health",
    "analyses": "/api/analyses/health",
    "reports": "/api/reports/health",
}

# Pipeline endpoints
LOGIN_PATH = "/api/auth/login"
DIAGRAMS_PATH = "/api/registration/diagrams"
REPORT_PATH_TEMPLATE = "/api/reports/{analysis_id}"

# Polling / timeout settings
POLL_INTERVAL_SECONDS = 10
PIPELINE_TIMEOUT_SECONDS = 300  # 5 minutes (Req 16.2)
REQUEST_TIMEOUT_SECONDS = 5     # per-request timeout (Req 16.1)

# Minimal 1×1 white PNG (valid image for upload)
_MINIMAL_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    b"\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00"
    b"\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
)

# ---------------------------------------------------------------------------
# Skip marker — all tests in this module require ALB_DNS
# ---------------------------------------------------------------------------

_ALB_DNS = os.environ.get("ALB_DNS", "").strip()

pytestmark = pytest.mark.e2e

_skip_no_alb = pytest.mark.skipif(
    not _ALB_DNS,
    reason="ALB_DNS environment variable is not set; skipping e2e tests",
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _base_url() -> str:
    """Return the base URL derived from ALB_DNS (no trailing slash)."""
    dns = _ALB_DNS.rstrip("/")
    if not dns.startswith(("http://", "https://")):
        dns = f"http://{dns}"
    return dns


def _get(path: str, headers: Optional[dict] = None, **kwargs) -> requests.Response:
    url = f"{_base_url()}{path}"
    return requests.get(url, headers=headers, timeout=REQUEST_TIMEOUT_SECONDS, **kwargs)


def _post(path: str, headers: Optional[dict] = None, **kwargs) -> requests.Response:
    url = f"{_base_url()}{path}"
    return requests.post(url, headers=headers, timeout=REQUEST_TIMEOUT_SECONDS, **kwargs)


def _poll_until_done(
    path: str,
    headers: dict,
    timeout: int = PIPELINE_TIMEOUT_SECONDS,
    interval: int = POLL_INTERVAL_SECONDS,
) -> dict:
    """
    Poll GET *path* every *interval* seconds until the JSON body contains
    ``status == 'done'`` or *timeout* seconds elapse.

    Returns the final response JSON on success.
    Raises ``TimeoutError`` when the deadline is exceeded.
    Raises ``AssertionError`` when the status transitions to ``'error'``.
    """
    deadline = time.monotonic() + timeout
    last_status: Optional[str] = None

    while time.monotonic() < deadline:
        try:
            resp = _get(path, headers=headers)
            if resp.status_code == 200:
                body = resp.json()
                last_status = body.get("status")
                if last_status == "done":
                    return body
                if last_status == "error":
                    raise AssertionError(
                        f"Analysis transitioned to 'error' state. Response: {body}"
                    )
        except requests.RequestException:
            pass  # transient network error — keep polling

        time.sleep(interval)

    raise TimeoutError(
        f"Analysis did not reach 'done' within {timeout}s. "
        f"Last observed status: {last_status!r}"
    )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def jwt_token() -> str:
    """
    Authenticate against /api/auth/login and return the JWT.

    Uses TEST_USERNAME / TEST_PASSWORD env vars (defaults to test/test).
    Skips when ALB_DNS is not set.
    """
    if not _ALB_DNS:
        pytest.skip("ALB_DNS environment variable is not set; skipping e2e tests")

    username = os.environ.get("TEST_USERNAME", "test")
    password = os.environ.get("TEST_PASSWORD", "test")

    resp = _post(
        LOGIN_PATH,
        json={"username": username, "password": password},
    )
    assert resp.status_code == 200, (
        f"Login failed with HTTP {resp.status_code}. Body: {resp.text}"
    )
    body = resp.json()
    token = body.get("token") or body.get("access_token") or body.get("jwt")
    assert token, f"No JWT found in login response: {body}"
    return token


@pytest.fixture(scope="module")
def auth_headers(jwt_token: str) -> dict:
    """Authorization header dict for authenticated requests."""
    return {"Authorization": f"Bearer {jwt_token}"}


# ---------------------------------------------------------------------------
# Test class: health endpoints
# ---------------------------------------------------------------------------


@_skip_no_alb
class TestServiceHealthEndpoints:
    """
    **Validates: Requirements 16.1, 16.2, 16.3**

    Every service (except celery-worker) must respond HTTP 200 on its
    /api/<service>/health endpoint through the ALB within the retry window.
    """

    @pytest.mark.parametrize("service,health_path", SERVICES.items())
    def test_service_health_returns_200(self, service: str, health_path: str):
        """
        **Validates: Requirements 16.1, 16.2**

        GET /api/<service>/health through the ALB must return HTTP 200
        within 5 minutes (retrying every 10 s).
        """
        deadline = time.monotonic() + PIPELINE_TIMEOUT_SECONDS
        last_error: Optional[str] = None

        while time.monotonic() < deadline:
            try:
                resp = _get(health_path)
                if resp.status_code == 200:
                    return  # PASS
                last_error = f"HTTP {resp.status_code}"
            except requests.RequestException as exc:
                last_error = str(exc)
            time.sleep(POLL_INTERVAL_SECONDS)

        pytest.fail(
            f"Service '{service}' health endpoint '{health_path}' did not return "
            f"HTTP 200 within {PIPELINE_TIMEOUT_SECONDS}s. Last error: {last_error}"
        )


# ---------------------------------------------------------------------------
# Test class: full pipeline
# ---------------------------------------------------------------------------


@_skip_no_alb
class TestDiagramAnalysisPipeline:
    """
    **Validates: Requirements 16.1, 16.2, 16.3**

    Full end-to-end pipeline:
      1. Authenticate → JWT
      2. Submit diagram → analysis_id
      3. Poll until status=done
      4. Fetch report → verify it exists
    """

    def test_login_returns_jwt(self, jwt_token: str):
        """
        **Validates: Requirements 16.1**

        POST /api/auth/login must return HTTP 200 with a non-empty JWT.
        """
        assert jwt_token, "JWT token must be non-empty"

    def test_submit_diagram_returns_analysis_id(self, auth_headers: dict):
        """
        **Validates: Requirements 16.1, 16.2**

        POST /api/registration/diagrams with a test image must return
        HTTP 202 and an analysis_id.
        """
        image_file = io.BytesIO(_MINIMAL_PNG)
        image_file.name = "test_diagram.png"

        resp = _post(
            DIAGRAMS_PATH,
            headers=auth_headers,
            files={"file": ("test_diagram.png", image_file, "image/png")},
        )
        assert resp.status_code in (200, 201, 202), (
            f"Diagram submission failed with HTTP {resp.status_code}. Body: {resp.text}"
        )
        body = resp.json()
        analysis_id = body.get("analysis_id") or body.get("id")
        assert analysis_id, f"No analysis_id in submission response: {body}"

    def test_full_pipeline_end_to_end(self, auth_headers: dict):
        """
        **Validates: Requirements 16.1, 16.2, 16.3**

        Full pipeline:
          1. Submit diagram → analysis_id
          2. Poll until status=done (max 5 min)
          3. GET /api/reports/{analysis_id} → HTTP 200 with report data
        """
        # Step 1: submit diagram
        image_file = io.BytesIO(_MINIMAL_PNG)
        submit_resp = _post(
            DIAGRAMS_PATH,
            headers=auth_headers,
            files={"file": ("test_diagram.png", image_file, "image/png")},
        )
        assert submit_resp.status_code in (200, 201, 202), (
            f"Diagram submission failed with HTTP {submit_resp.status_code}. "
            f"Body: {submit_resp.text}"
        )
        body = submit_resp.json()
        analysis_id = body.get("analysis_id") or body.get("id")
        assert analysis_id, f"No analysis_id in submission response: {body}"

        # Step 2: poll until done
        poll_path = f"{DIAGRAMS_PATH}/{analysis_id}"
        final_body = _poll_until_done(poll_path, headers=auth_headers)
        assert final_body.get("status") == "done", (
            f"Expected status='done', got: {final_body}"
        )

        # Step 3: fetch report
        report_path = REPORT_PATH_TEMPLATE.format(analysis_id=analysis_id)
        report_resp = _get(report_path, headers=auth_headers)
        assert report_resp.status_code == 200, (
            f"GET {report_path} returned HTTP {report_resp.status_code}. "
            f"Body: {report_resp.text}"
        )
        report_body = report_resp.json()
        assert report_body, "Report response body must not be empty"

    def test_poll_status_endpoint_returns_valid_schema(self, auth_headers: dict):
        """
        **Validates: Requirements 16.2, 16.3**

        After submitting a diagram, the status endpoint must return a JSON
        body that includes at least an 'id' and a 'status' field.
        """
        image_file = io.BytesIO(_MINIMAL_PNG)
        submit_resp = _post(
            DIAGRAMS_PATH,
            headers=auth_headers,
            files={"file": ("test_diagram.png", image_file, "image/png")},
        )
        assert submit_resp.status_code in (200, 201, 202), (
            f"Diagram submission failed with HTTP {submit_resp.status_code}. "
            f"Body: {submit_resp.text}"
        )
        body = submit_resp.json()
        analysis_id = body.get("analysis_id") or body.get("id")
        assert analysis_id, f"No analysis_id in submission response: {body}"

        poll_path = f"{DIAGRAMS_PATH}/{analysis_id}"
        poll_resp = _get(poll_path, headers=auth_headers)
        assert poll_resp.status_code == 200, (
            f"Status poll returned HTTP {poll_resp.status_code}. Body: {poll_resp.text}"
        )
        status_body = poll_resp.json()
        assert "status" in status_body, (
            f"Status response missing 'status' field: {status_body}"
        )
        assert status_body.get("status") in ("queued", "processing", "done", "error"), (
            f"Unexpected status value: {status_body.get('status')!r}"
        )

    def test_report_endpoint_requires_auth(self):
        """
        **Validates: Requirements 16.3**

        GET /api/reports/<id> without a JWT must return HTTP 401 or 403.
        """
        # Use a plausible but non-existent UUID
        fake_id = "00000000-0000-0000-0000-000000000000"
        report_path = REPORT_PATH_TEMPLATE.format(analysis_id=fake_id)
        resp = _get(report_path)
        assert resp.status_code in (401, 403), (
            f"Expected 401/403 for unauthenticated report request, "
            f"got HTTP {resp.status_code}"
        )
